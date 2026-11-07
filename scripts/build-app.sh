#!/bin/bash
# Builds LocalAIBar.app into ./build (and optionally copies it to /Applications with --install).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/LocalAIBar.app
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

sign() { codesign --force --sign - --timestamp=none "$@"; }  # ad-hoc; updates are verified by Sparkle's EdDSA key

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/LocalAIBar" "$APP/Contents/MacOS/LocalAIBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sparkle (app updates), signed inside out as its documentation lists.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/LocalAIBar" 2>/dev/null || true
S="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$S/XPCServices/Installer.xpc"
sign "$S/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
sign "$S/Autoupdate"
sign "$S/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x LocalAIBar 2>/dev/null || true
  sleep 1
  rm -rf /Applications/LocalAIBar.app
  cp -R "$APP" /Applications/
  open /Applications/LocalAIBar.app
  echo "Installed to /Applications"
fi
