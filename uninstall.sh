#!/bin/bash
# Move the Mac app to the Trash and remove its Chrome registration and saved
# settings. The vocabulary list is kept. The extension itself is removed from
# chrome://extensions.
set -euo pipefail

APP="$HOME/Applications/FloatSubs.app"
pkill -x FloatSubs 2>/dev/null || true
if [ -d "$APP" ]; then
  mv "$APP" "$HOME/.Trash/FloatSubs-$(date +%Y%m%d-%H%M%S).app"
fi
rm -f "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/io.github.wrab12.floatsubs.json"
defaults delete io.github.wrab12.floatsubs 2>/dev/null || true
echo "Removed. Also remove “悬浮字幕 FloatSubs” in chrome://extensions."
echo "Your vocabulary list is kept at ~/Library/Application Support/FloatSubs/vocabulary.json"
