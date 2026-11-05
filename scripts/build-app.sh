#!/bin/bash
# Builds LocalAIBar.app into ./build (and optionally copies it to /Applications with --install).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/LocalAIBar.app
swift build -c release
BIN="$(swift build -c release --show-bin-path)/LocalAIBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LocalAIBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x LocalAIBar 2>/dev/null || true
  rm -rf /Applications/LocalAIBar.app
  cp -R "$APP" /Applications/
  open /Applications/LocalAIBar.app
  echo "Installed to /Applications"
fi
