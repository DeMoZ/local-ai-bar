# LocalAIBar

A macOS menu bar app for a local LLM (llama.cpp `llama-server`) running on another PC in your LAN,
behind a small control service with a Bearer token (PowerShell scripts in [`server/`](server): Windows PC, or
PowerShell 7 on a Mac for models on the same machine). Where to put models and what goes with them:
[`docs/models.md`](docs/models.md).

## Features

- **LAN search**: scans the Mac's local subnets for the control service and shows found PCs by
  `.local` name (mDNS or NetBIOS) or by IP.
- **Status** in the menu bar icon and the popover: running / loading / stopped / unreachable / wrong token.
- **Connect / disconnect** (start / stop monitoring) and **turn the model on / off**.
- **Model info** from llama-server: file, quantization, parameters, size, context (current / max),
  input types, slots in use, server health, uptime, ping.
- **Model** picked from the PC's models folder (👁 = image input) and **context size** (16k / 32k / 64k): saved
  on the PC, the model restarts with them.
- **Crash notifications** (macOS notifications) and optional **auto-restart** of a crashed model by the PC.
- **PC load**: memory, CPU, GPU load and GPU memory, memory of llama-server.
- **Live speed** next to the menu bar icon while a request runs (tokens per second, "…" while the prompt is read).
- **Speed test**: a short generation that shows tokens per second.
- **Copy API endpoint** (OpenAI-compatible `http://<host>:<port>/v1`) and **open the chat web UI**.
- **Launch at login**.
- **Updates** through Sparkle (checks by itself; **Обновления** checks now).
- **♥ Поддержать**: ways to support the project, from the public [`DeMoZ/donations`](https://github.com/DeMoZ/donations) repository (links are never hardcoded).
- The token is kept in the **macOS Keychain**, never in files or UserDefaults.
  It can be typed in or imported from the control service's `config.json`
  (`token`, `controlPort`, `llamaPort` are read from it).

## Build

Requires macOS 14+ and Xcode Command Line Tools.

```bash
./scripts/build-app.sh            # -> build/LocalAIBar.app
./scripts/build-app.sh --install  # also copies to /Applications and launches it
```

On first network access macOS asks for **Local Network** permission; allow it
(System Settings → Privacy & Security → Local Network).

The app is ad-hoc signed, so after a rebuild macOS may ask once more for Keychain access to the token.

## Release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, add `docs/releases/v<version>.md`.
2. Merge to `main`, then on a clean, up-to-date `main` run `./scripts/release.sh`.

It builds the app, zips it, signs the zip with the Sparkle EdDSA key (Keychain account `LocalAIBar`, or
`$SPARKLE_PRIVATE_KEY`), writes `appcast.xml` and publishes both as a GitHub release. The app reads
`releases/latest/download/appcast.xml`.

### Developer ID signing and notarization (optional)

Without them the app is ad-hoc signed and macOS asks to confirm the first launch (right-click → Open). With an Apple
Developer Program membership:

1. Xcode → Settings → Accounts → Manage Certificates → **+** → *Developer ID Application*.
2. `xcrun notarytool store-credentials LocalAIBar-notary --apple-id <apple id> --team-id <team id>` (asks for an
   app-specific password from account.apple.com).
3. Release with both set:
   `DEVELOPER_ID="Developer ID Application: <Name> (<TEAMID>)" NOTARY_PROFILE=LocalAIBar-notary ./scripts/release.sh`

`build-app.sh` then signs with the hardened runtime and a timestamp; `release.sh` notarizes, staples and checks
the app with `spctl` before zipping. Sparkle updates keep working (they are verified by the EdDSA key). After the
first Developer ID build macOS asks once more for Keychain access to the token.

## Server API used

| Service | Endpoint | Auth |
|---|---|---|
| control | `GET /status`, `POST /start`, `POST /stop` → `{"status": "running" \| "loading" \| "stopped", "crash": {"at", "exitCode", "count", "restarted"} \| null, "autoRestart"}` | Bearer |
| control | `GET /config` → `{"ctx", "ngl", "parallel", "ubatch", "model", "modelId", "autoRestart"}` (no token); `POST /config` with any of `{"ctx": N, "model": "<id>", "autoRestart": bool}` → the same plus `"status", "restarted"` | Bearer |
| control | `GET /models` → `{"modelsDir", "models": [{"id", "name", "sizeBytes", "vision", "current"}]}` ([docs/models.md](docs/models.md)) | Bearer |
| control | `GET /metrics` → `{"cpu", "gpu", "ramTotal", "ramUsed", "gpuDedicated", "gpuShared", "llamaRam"}` (bytes, %, null if unknown) | Bearer |
| llama-server | `GET /health`, `GET /v1/models`, `GET /props`, `GET /slots`, `POST /completion` | Bearer (same token) |

## Control service

`server/scripts/` holds `model-lib.ps1` and `control-server.ps1`. On the Windows PC they run from the scheduled task
`LocalAI-Control` with settings in `D:\Ai\config.json`; on a Mac, with PowerShell 7 from a LaunchAgent. Setup,
`config.json` and the models folder: [docs/models.md](docs/models.md).

The service checks for a crashed `llama-server` every 3 seconds (`logs/crashes.log`) and restarts it when
`autoRestart` is on (at most 3 times in 10 minutes).

To update the service on a PC, run in PowerShell there (as Administrator):

```powershell
irm https://raw.githubusercontent.com/DeMoZ/local-ai-bar/main/server/update-windows.ps1 | iex
```

It downloads and syntax-checks the scripts, keeps the old ones as `.bak`, restarts the task (and the model, if it was
on) and prints the settings and the number of models found.
