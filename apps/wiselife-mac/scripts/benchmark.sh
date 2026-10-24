#!/bin/sh
set -eu
COMPANION_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
xcodebuild -jobs 6 -project "$COMPANION_ROOT/WiseLifeMac.xcodeproj" -scheme CompanionBenchmark \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$COMPANION_ROOT/build" -clonedSourcePackagesDirPath "$COMPANION_ROOT/.build/xcode-packages" \
  -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- build
exec "$COMPANION_ROOT/build/Build/Products/Release/CompanionBenchmark" "$@"
