# LocalAIBar

A macOS menu bar app for a local LLM (llama.cpp `llama-server`) running on another PC in your LAN,
behind a small control service with `/status`, `/start`, `/stop`, `/config` endpoints and a Bearer token
(PowerShell scripts for the PC are in [`windows/`](windows)).

## Features

- **LAN search**: scans the Mac's local subnets for the control service and shows found PCs by
  `.local` name (mDNS or NetBIOS) or by IP.
- **Status** in the menu bar icon and the popover: running / loading / stopped / unreachable / wrong token.
- **Connect / disconnect** (start / stop monitoring) and **turn the model on / off**.
- **Model info** from llama-server: file, quantization, parameters, size, context (current / max),
  input types, slots in use, server health, uptime, ping.
- **Context size** (16k / 32k / 64k): saved on the PC, the model restarts with it.
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

## Server API used

| Service | Endpoint | Auth |
|---|---|---|
| control | `GET /status`, `POST /start`, `POST /stop` → `{"status": "running" \| "loading" \| "stopped"}` | Bearer |
| control | `GET /config` → `{"ctx", "ngl", "parallel", "ubatch", "model"}` (no token); `POST /config {"ctx": N}` → `{"status", "ctx", "restarted"}` | Bearer |
| llama-server | `GET /health`, `GET /v1/models`, `GET /props`, `GET /slots`, `POST /completion` | Bearer (same token) |

## PC control service (Windows)

`windows/scripts/` holds `model-lib.ps1` and `control-server.ps1` (run by the scheduled task `LocalAI-Control`,
settings in `D:\Ai\config.json`). To update a PC that already has the service: copy the text of
`windows/update-local-ai.ps1` to the clipboard, then in PowerShell on the PC save it as a file and run it. It backs up
both scripts as `.bak`, writes the new ones, restarts the task (and the model, if it was on) and checks `/config`.
