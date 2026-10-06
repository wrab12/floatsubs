#!/bin/bash
# Build the Mac app (if needed), copy it to ~/Applications and register it with
# Chrome as the native messaging host for the FloatSubs extension.
set -euo pipefail
cd "$(dirname "$0")"

EXT_ID=celglieaihkffjgoemdkbmmlccclnhkp # pinned by the "key" in extension/manifest.json
HOST=io.github.wrab12.floatsubs
APP="$HOME/Applications/FloatSubs.app"
HOST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
BIN=build/FloatSubs.app/Contents/MacOS/FloatSubs

if [ ! -x "$BIN" ] || [ mac/main.m -nt "$BIN" ] || [ mac/Info.plist -nt "$BIN" ]; then
  bash build.sh
fi

pkill -x FloatSubs 2>/dev/null || true # stop a running copy before replacing it
mkdir -p "$HOME/Applications" "$HOST_DIR"
ditto build/FloatSubs.app "$APP"

cat >"$HOST_DIR/$HOST.json" <<EOF
{
  "name": "$HOST",
  "description": "FloatSubs floating subtitle window",
  "path": "$APP/Contents/MacOS/FloatSubs",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
EOF

echo "Installed $APP"
echo "Registered $HOST_DIR/$HOST.json"
