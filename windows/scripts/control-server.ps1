. "$PSScriptRoot\model-lib.ps1"

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://+:$($script:Cfg.controlPort)/")
$listener.Start()

$script:MinCtx = 2048
$script:MaxCtx = 262144

function Send-Json($res, [int]$code, $obj) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress))
    $res.StatusCode = $code
    $res.ContentType = 'application/json; charset=utf-8'
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Read-JsonBody($req) {
    $reader = [IO.StreamReader]::new($req.InputStream, [Text.Encoding]::UTF8)
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $null }
}

# Launch settings without the token.
function Get-PublicConfig {
    $c = $script:Cfg
    @{
        ctx      = [int]$c.ctx
        ngl      = [int]$c.ngl
        parallel = [int](Get-ConfigValue 'parallel' 1)
        ubatch   = [int](Get-ConfigValue 'ubatch' 256)
        model    = [IO.Path]::GetFileName($c.modelPath)
    }
}

function Set-Context($res, $body) {
    $n = 0
    if ($null -eq $body -or -not [int]::TryParse("$($body.ctx)", [ref]$n)) {
        Send-Json $res 400 @{ error = 'ctx must be an integer' }; return
    }
    if ($n -lt $script:MinCtx -or $n -gt $script:MaxCtx) {
        Send-Json $res 400 @{ error = "ctx must be between $($script:MinCtx) and $($script:MaxCtx)" }; return
    }
    Read-Config
    Set-ConfigValue 'ctx' $n
    Save-Config
    # Restart only if the model is on; a stopped model picks the value up on the next start.
    $restarted = $false
    if (Get-LlamaProcess) {
        Stop-Model
        Start-Model
        $restarted = $true
    }
    Send-Json $res 200 @{ status = (Get-ModelStatus); ctx = $n; restarted = $restarted }
}

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response
    try {
        $res.Headers.Add('Access-Control-Allow-Origin', '*')
        $res.Headers.Add('Access-Control-Allow-Headers', 'Authorization, Content-Type')
        $res.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        $res.Headers.Add('Access-Control-Allow-Private-Network', 'true')

        if ($req.HttpMethod -eq 'OPTIONS') { $res.StatusCode = 204; continue }

        if ($req.Headers['Authorization'] -ne "Bearer $($script:Cfg.token)") {
            Send-Json $res 401 @{ error = 'unauthorized' }; continue
        }

        switch ($req.Url.AbsolutePath) {
            '/start'  { Start-Model; Send-Json $res 200 @{ status = (Get-ModelStatus) } }
            '/stop'   { Stop-Model;  Send-Json $res 200 @{ status = (Get-ModelStatus) } }
            '/status' { Send-Json $res 200 @{ status = (Get-ModelStatus) } }
            '/config' {
                if ($req.HttpMethod -eq 'POST') { Set-Context $res (Read-JsonBody $req) }
                else { Read-Config; Send-Json $res 200 (Get-PublicConfig) }
            }
            default   { Send-Json $res 404 @{ error = 'not found' } }
        }
    } catch {
        try { Send-Json $res 500 @{ error = $_.Exception.Message } } catch {}
    } finally {
        $res.Close()
    }
}
