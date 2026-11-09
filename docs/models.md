# Models for LocalAIBar: where to put them and what goes with them

Instructions for an AI agent (or a person) who prepares a machine so that LocalAIBar finds its models, switches
between them and runs them. Follow the rules literally; the control service checks nothing beyond what is written
here.

## How LocalAIBar sees models

LocalAIBar never reads a disk. It asks the **control service** (`server/scripts/control-server.ps1`) on the machine
that runs the models:

| Request | What the service does |
|---|---|
| `GET /models` | Lists the `.gguf` models in the models folder (rules below). |
| `POST /config {"model": "<id>"}` | Switches `config.json` to that model and restarts `llama-server` if it is on. |
| `POST /config {"ctx": N}` | Saves a new context size, restarts a running model. |
| `GET /status`, `POST /start`, `POST /stop` | Model state, on, off. |

Every request needs the header `Authorization: Bearer <token>`, the token from `config.json`. Never print the
token, never put it in files that go to git, chat or logs.

The service and the models are always on the **same machine**:

- **Remote** (the usual case): a Windows PC in the LAN runs the service and `llama-server`; LocalAIBar on the Mac
  connects to `<pc-name>.local`.
- **Local**: the Mac itself runs the service (PowerShell 7) and `llama-server`; LocalAIBar connects to `127.0.0.1`.

## Folder layout

```
<root>\                         D:\Ai on the PC, e.g. ~/LocalAI on a Mac
  config.json                   service settings (below), contains the token
  scripts\control-server.ps1    the service (from server/scripts in this repo)
  scripts\model-lib.ps1
  logs\                         created by the service: llama.out.log, llama.err.log, crashes.log
  llama.pid                     created by the service while the model runs; do not touch
  models\                       the models folder ("modelsDir" in config.json, default <root>\models)
    <model-folder>\             one folder per model (recommended)
      <name>.gguf               the model
      mmproj-<name>.gguf        optional: image input (vision projector) for this model
      localai.json              optional: settings for this model
    <big-model>\                a model split into parts
      <name>-00001-of-00003.gguf
      <name>-00002-of-00003.gguf
      <name>-00003-of-00003.gguf
    <single>.gguf               allowed: a model straight in models\ (no mmproj, no localai.json)
```

Rules the service applies (`Get-Models` in `server/scripts/model-lib.ps1`):

1. Every `*.gguf` anywhere under the models folder (subfolders included) is a model, except:
   - files whose name starts with `mmproj` (vision projectors, not models);
   - parts `-00002-of-000NN` and later of a split model. Only part `-00001-of-000NN` is listed; its size is the
     sum of all parts, and llama.cpp loads the other parts by itself. All parts must be in the same folder and keep
     their original names.
2. A model's **id** is its path inside the models folder with `/`, e.g. `gemma-4-26b/gemma-4-26B_q4_0-it.gguf`.
   Renaming or moving a file changes its id; select it again in LocalAIBar afterwards.
3. The **name** shown in LocalAIBar is `"name"` from `localai.json`, else the file name without `.gguf` (and
   without the `-00001-of-000NN` part).
4. **Image input**: a model gets `--mmproj` when its own folder has exactly one `mmproj*.gguf`, or when
   `localai.json` names one with `"mmproj": "<file name>"`. Several `mmproj` files and no `"mmproj"` setting means
   none is used. `"mmproj": false` turns it off for that model; `"mmproj": false` in `config.json` turns it off
   for all models. A model straight in the models folder never gets an mmproj file guessed for it. LocalAIBar marks
   models with image input with 👁. The mmproj file must belong to the same base model (same architecture and
   size): take it from the same download page as the model.
5. Put **one model per folder**. Different quantizations of one model can share a folder only if they need the
   same `localai.json`; otherwise give each its own folder.
6. Only plain files count: no shortcuts, no `.lnk`. Symbolic links work if they point to real files on a local disk.
7. Anything else in a model folder (`README.md`, `LICENSE`, `.txt`, chat templates) is ignored, so the files from
   a model's download page can be kept there.

## localai.json (optional, per model)

UTF-8 JSON in the model's folder. All fields are optional.

```json
{
  "name": "Gemma 4 26B (Q4_0)",
  "ctx": 32768,
  "ngl": 99,
  "parallel": 1,
  "ubatch": 256,
  "mmproj": "mmproj-gemma-4-26B-f16.gguf",
  "extraArgs": ["--temp", "0.7", "--reasoning-budget", "0"]
}
```

| Field | Meaning |
|---|---|
| `name` | Name in LocalAIBar. |
| `ctx`, `ngl`, `parallel`, `ubatch` | Copied into `config.json` **when this model is selected** (later the context can be changed in LocalAIBar). `ctx` is the context size in tokens, `ngl` the number of layers on the GPU (99 = all). |
| `mmproj` | mmproj file name in this folder, or `false` for no image input. |
| `extraArgs` | More `llama-server` arguments, added at every start of this model. Each argument is its own string, without spaces or quotes inside (they are not escaped). Never put `--api-key`, `--port`, `--host`, `-m`, `-c` here: the service sets them. Check a flag with `llama-server --help` of the installed version first: an unknown flag makes the model fail to start. |

Choose `ctx` so that the model plus its context fit in the GPU memory (on an iGPU: the RAM given to the GPU). If
the model then fails to start or crashes, lower `ctx` (see `logs\llama.err.log`).

## config.json (one per machine)

```json
{
  "token": "<random string, 32+ characters>",
  "modelPath": "D:\\Ai\\models\\gemma-4-26b\\gemma-4-26B_q4_0-it.gguf",
  "modelsDir": "D:\\Ai\\models",
  "llamaServerPath": "C:\\path\\to\\llama-server.exe",
  "llamaPort": 8080,
  "controlPort": 8081,
  "ctx": 32768,
  "ngl": 99,
  "parallel": 1,
  "ubatch": 256,
  "autoRestart": false
}
```

- `modelPath` is the model that starts; LocalAIBar changes it when another model is selected. It may point outside
  `modelsDir`, but then that model is not in the list.
- `modelsDir` is optional (default `<root>\models`).
- `autoRestart` (also a switch in LocalAIBar's settings): the service starts a crashed model again, at most 3 times
  in 10 minutes.
- In JSON, every `\` of a Windows path is written `\\`. Save as UTF-8.
- The service re-reads `config.json` before every model start, so a hand edit takes effect at the next
  off / on in LocalAIBar.

## Adding a model (checklist)

1. Download the `.gguf` (all parts, if split) and, for image input, the matching `mmproj-*.gguf`.
2. Create `<modelsDir>\<short-folder-name>\` and put the files there with their original names.
3. Optional: write `localai.json` (at least `name` and a `ctx` that fits the memory).
4. Check that the service sees it, from the machine itself (the token is read from the file and never printed):
   - Windows PowerShell:
     `$c = Get-Content D:\Ai\config.json -Raw | ConvertFrom-Json; (Invoke-RestMethod "http://127.0.0.1:$($c.controlPort)/models" -Headers @{ Authorization = "Bearer $($c.token)" }).models | Format-Table id, name, vision, current`
   - macOS / Linux (PowerShell 7 or curl with the token from the file, never on the command line).
5. In LocalAIBar: Settings → **Модель** → pick it → **Применить**. The model restarts with it.

## Removing a model

Delete its folder (or file). If it was the current model, select another one in LocalAIBar first; otherwise the next
start fails because `modelPath` points to a missing file.

## A new machine

### Windows PC

1. `llama-server.exe` from llama.cpp (e.g. `winget install ggml.llamacpp`, Vulkan build for AMD / Intel GPUs).
2. `D:\Ai\scripts\` with `model-lib.ps1` and `control-server.ps1` from `server/scripts/`, `D:\Ai\config.json` as
   above, models in `D:\Ai\models\`.
3. A scheduled task `LocalAI-Control`, at startup, "Run with highest privileges" (the service listens on all
   addresses), action:
   `powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "D:\Ai\scripts\control-server.ps1"`.
4. Windows Firewall: allow inbound TCP on `controlPort` and `llamaPort` for the private network.
5. For long prompts on an iGPU, raise the GPU timeout (TDR), or the driver resets the GPU and the model crashes:
   `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers`, DWORD `TdrDelay` = 60 and `TdrDdiDelay` = 60, then
   reboot.

Later updates of the service: `server/update-windows.ps1` (its first lines say how to run it).

### Mac (models on the same Mac)

1. `brew install llama.cpp powershell` (`llama-server` is then in `/opt/homebrew/bin`).
2. `~/LocalAI/scripts/` with the two scripts, `~/LocalAI/config.json` with Mac paths (`"/Users/<you>/LocalAI/models"`,
   `"llamaServerPath": "/opt/homebrew/bin/llama-server"`, `ngl` 99 on Apple Silicon), models in
   `~/LocalAI/models/`.
3. Start it at login with a LaunchAgent `~/Library/LaunchAgents/io.github.demoz.localai-control.plist` that runs
   `/opt/homebrew/bin/pwsh -NoProfile -File /Users/<you>/LocalAI/scripts/control-server.ps1` with `RunAtLoad`
   and `KeepAlive` true, then `launchctl load` it.
4. In LocalAIBar: address `127.0.0.1`, the ports and the token from that `config.json`.

On a Mac the PC load panel shows memory and CPU only (GPU memory is the same RAM).
