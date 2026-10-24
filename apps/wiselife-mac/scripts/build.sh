#!/bin/sh
set -eu
COMPANION_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPANION_CONFIGURATION=${CONFIGURATION:-Release}
xcodebuild -jobs 6 -project "$COMPANION_ROOT/WiseLifeMac.xcodeproj" -scheme WiseLifeCompanion \
  -configuration "$COMPANION_CONFIGURATION" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$COMPANION_ROOT/build" -clonedSourcePackagesDirPath "$COMPANION_ROOT/.build/xcode-packages" \
  -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- build
mkdir -p "$COMPANION_ROOT/dist"
COMPANION_STAGE=$(mktemp -d "$COMPANION_ROOT/dist/.package-XXXXXX")
companion_cleanup() {
  if [ -d "$COMPANION_STAGE/previous.app" ] && [ ! -e "$COMPANION_ROOT/dist/WiseLifeCompanion.app" ]; then
    mv "$COMPANION_STAGE/previous.app" "$COMPANION_ROOT/dist/WiseLifeCompanion.app"
  fi
  rm -rf "$COMPANION_STAGE"
}
trap companion_cleanup EXIT HUP INT TERM
# ditto merges directory contents. Stage a clean bundle so Debug-only dylibs
# cannot remain in a later Release package and invalidate its resource seal.
ditto "$COMPANION_ROOT/build/Build/Products/$COMPANION_CONFIGURATION/WiseLifeCompanion.app" "$COMPANION_STAGE/WiseLifeCompanion.app"
codesign --verify --deep --strict "$COMPANION_STAGE/WiseLifeCompanion.app"
if [ -e "$COMPANION_ROOT/dist/WiseLifeCompanion.app" ]; then
  mv "$COMPANION_ROOT/dist/WiseLifeCompanion.app" "$COMPANION_STAGE/previous.app"
fi
mv "$COMPANION_STAGE/WiseLifeCompanion.app" "$COMPANION_ROOT/dist/WiseLifeCompanion.app"
ditto -c -k --keepParent "$COMPANION_ROOT/dist/WiseLifeCompanion.app" "$COMPANION_STAGE/WiseLifeCompanion-macOS.zip"
mv "$COMPANION_STAGE/WiseLifeCompanion-macOS.zip" "$COMPANION_ROOT/dist/WiseLifeCompanion-macOS.zip"
printf 'Mac App: %s\n' "$COMPANION_ROOT/dist/WiseLifeCompanion.app"
