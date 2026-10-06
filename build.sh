#!/bin/bash
# Build mac/main.m into build/FloatSubs.app (needs only the Xcode Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/FloatSubs.app
mkdir -p "$APP/Contents/MacOS"
clang -fobjc-arc -fmodules -O2 -Wall -mmacosx-version-min=12.0 \
  -framework Cocoa -framework CoreServices -framework NaturalLanguage -framework AVFoundation \
  mac/main.m -o "$APP/Contents/MacOS/FloatSubs"
cp mac/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null
echo "Built $APP"
