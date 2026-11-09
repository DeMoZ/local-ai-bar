. (Join-Path $PSScriptRoot 'model-lib.ps1')

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://+:$($script:Cfg.controlPort)/")
$listener.Start()

$script:MinCtx = 2048
$script:MaxCtx = 262144

function Send-Json($res, [int]$code, $obj) {
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $obj -Compress -Depth 5))
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

function Has($obj, [string]$name) { $obj -and $obj.PSObject.Properties[$name] }

# Model state plus the last crash and the auto-restart setting (older apps read only "status").
function Get-StatusReply {
    [ordered]@{
        status      = (Get-ModelStatus)
        crash       = $script:LastCrash
        autoRestart = [bool](Get-ConfigValue 'autoRestart' $false)
    }
}

# Launch settings without the token.
function Get-PublicConfig {
    $c = $script:Cfg
    [ordered]@{
        ctx         = [int]$c.ctx
        ngl         = [int]$c.ngl
        parallel    = [int](Get-ConfigValue 'parallel' 1)
        ubatch      = [int](Get-ConfigValue 'ubatch' 256)
        model       = [IO.Path]::GetFileName($c.modelPath)
        modelId     = (Get-ModelId $c.modelPath)
        autoRestart = [bool](Get-ConfigValue 'autoRestart' $false)
    }
}

# POST /config {"ctx"?: int, "model"?: id from GET /models, "autoRestart"?: bool} — any subset.
# A new ctx or model restarts a running model; a stopped one picks them up on the next start.
function Set-Config($res, $body) {
    if ($null -eq $body) { Send-Json $res 400 @{ error = 'JSON body expected' }; return }
    $n = 0
    if (Has $body 'ctx') {
        if (-not [int]::TryParse("$($body.ctx)", [ref]$n)) { Send-Json $res 400 @{ error = 'ctx must be an integer' }; return }
        if ($n -lt $script:MinCtx -or $n -gt $script:MaxCtx) {
            Send-Json $res 400 @{ error = "ctx must be between $($script:MinCtx) and $($script:MaxCtx)" }; return
        }
    }
    $modelPath = $null
    if (Has $body 'model') {
        $modelPath = Resolve-ModelId "$($body.model)"
        if (-not $modelPath) { Send-Json $res 400 @{ error = "no such model in $(Get-ModelsDir): $($body.model)" }; return }
    }
    if ((Has $body 'autoRestart') -and $body.autoRestart -isnot [bool]) {
        Send-Json $res 400 @{ error = 'autoRestart must be true or false' }; return
    }

    Read-Config
    $relaunch = $false
    if ($modelPath -and ($modelPath -ine [IO.Path]::GetFullPath($script:Cfg.modelPath))) { Set-Model $modelPath; $relaunch = $true }
    if ((Has $body 'ctx') -and $n -ne [int]$script:Cfg.ctx) { Set-ConfigValue 'ctx' $n; $relaunch = $true }
    if (Has $body 'autoRestart') { Set-ConfigValue 'autoRestart' $body.autoRestart }
    Save-Config

    $restarted = $false
    if ($relaunch -and (Get-LlamaProcess)) {
        Stop-Model
        Start-Model
        $restarted = $true
    }
    $reply = Get-PublicConfig
    $reply.status = (Get-ModelStatus)
    $reply.restarted = $restarted
    Send-Json $res 200 $reply
}

function Handle($req, $res) {
    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    $res.Headers.Add('Access-Control-Allow-Headers', 'Authorization, Content-Type')
    $res.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
    $res.Headers.Add('Access-Control-Allow-Private-Network', 'true')

    if ($req.HttpMethod -eq 'OPTIONS') { $res.StatusCode = 204; return }

    if ($req.Headers['Authorization'] -ne "Bearer $($script:Cfg.token)") {
        Send-Json $res 401 @{ error = 'unauthorized' }; return
    }

    switch ($req.Url.AbsolutePath) {
        '/start'   { Start-Model; Send-Json $res 200 (Get-StatusReply) }
        '/stop'    { Stop-Model;  Send-Json $res 200 (Get-StatusReply) }
        '/status'  { Send-Json $res 200 (Get-StatusReply) }
        '/models'  { Read-Config; Send-Json $res 200 @{ modelsDir = (Get-ModelsDir); models = @(Get-Models) } }
        '/metrics' { Send-Json $res 200 (Get-PcMetrics) }
        '/config'  {
            if ($req.HttpMethod -eq 'POST') { Set-Config $res (Read-JsonBody $req) }
            else { Read-Config; Send-Json $res 200 (Get-PublicConfig) }
        }
        default    { Send-Json $res 404 @{ error = 'not found' } }
    }
}

while ($listener.IsListening) {
    # Wait for a request, checking for a crashed model every 3 s meanwhile.
    $pending = $listener.BeginGetContext($null, $null)
    while (-not $pending.AsyncWaitHandle.WaitOne(3000)) {
        try { Test-ModelCrash } catch {}
    }
    $ctx = $listener.EndGetContext($pending)
    try { Test-ModelCrash } catch {}
    $res = $ctx.Response
    try {
        Handle $ctx.Request $res
    } catch {
        try { Send-Json $res 500 @{ error = $_.Exception.Message } } catch {}
    } finally {
        $res.Close()
    }
}
