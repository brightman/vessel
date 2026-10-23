#!/bin/sh
set -eu
DESKTOP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
xcodebuild -project "$DESKTOP_ROOT/WiseLifeDesktop.xcodeproj" -scheme WiseLifeDesktop \
  -configuration Release -destination 'platform=macOS' -derivedDataPath "$DESKTOP_ROOT/build" \
  CODE_SIGN_IDENTITY=- build
mkdir -p "$DESKTOP_ROOT/dist"
ditto "$DESKTOP_ROOT/build/Build/Products/Release/WiseLife.app" "$DESKTOP_ROOT/dist/WiseLife.app"
ditto -c -k --keepParent "$DESKTOP_ROOT/dist/WiseLife.app" "$DESKTOP_ROOT/dist/WiseLife-macOS.zip"
printf 'Mac App: %s\n' "$DESKTOP_ROOT/dist/WiseLife.app"
