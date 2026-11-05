# LocalAIBar

A macOS menu bar app for a local LLM (llama.cpp `llama-server`) running on another PC in your LAN,
behind a small control service with `/status`, `/start`, `/stop` endpoints and a Bearer token.

## Features

- **LAN search**: scans the Mac's local subnets for the control service and shows found PCs by
  `.local` name (mDNS or NetBIOS) or by IP.
- **Status** in the menu bar icon and the popover: running / loading / stopped / unreachable / wrong token.
- **Connect / disconnect** (start / stop monitoring) and **turn the model on / off**.
- **Model info** from llama-server: file, quantization, parameters, size, context (current / max),
  input types, slots in use, server health, uptime, ping.
- **Speed test**: a short generation that shows tokens per second.
- **Copy API endpoint** (OpenAI-compatible `http://<host>:<port>/v1`) and **open the chat web UI**.
- **Launch at login**.
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

## Server API used

| Service | Endpoint | Auth |
|---|---|---|
| control | `GET /status`, `POST /start`, `POST /stop` → `{"status": "running" \| "loading" \| "stopped"}` | Bearer |
| llama-server | `GET /health`, `GET /v1/models`, `GET /props`, `GET /slots`, `POST /completion` | Bearer (same token) |
