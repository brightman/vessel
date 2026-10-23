#!/bin/sh
set -eu
IOS_SYNC_REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$IOS_SYNC_REPO"
IOS_SYNC_TEMP=$(mktemp -d /private/tmp/wiselife-ios-sync.XXXXXX)
IOS_SYNC_SERVER_PID=''
IOS_SYNC_DEVICE=''
IOS_SYNC_BUILD=${WISELIFE_IOS_BUILD_DIR:-$IOS_SYNC_REPO/desktop/build/ios}
trap 'if [ -n "$IOS_SYNC_SERVER_PID" ]; then kill "$IOS_SYNC_SERVER_PID" 2>/dev/null || true; fi; if [ -n "$IOS_SYNC_DEVICE" ]; then xcrun simctl shutdown "$IOS_SYNC_DEVICE" >/dev/null 2>&1 || true; xcrun simctl delete "$IOS_SYNC_DEVICE" >/dev/null 2>&1 || true; fi; rm -rf "$IOS_SYNC_TEMP"' EXIT INT TERM
swiftc -swift-version 5 desktop/Shared/*.swift desktop/Sources/Core/*.swift desktop/Tests/PhoneFixtureServer.swift -o "$IOS_SYNC_TEMP/mac-fixture"
IOS_SYNC_DEVICE=$(xcrun simctl create 'WiseLife Desktop Sync Tests' com.apple.CoreSimulator.SimDeviceType.iPhone-Air com.apple.CoreSimulator.SimRuntime.iOS-26-3)
xcrun simctl boot "$IOS_SYNC_DEVICE"
xcrun simctl bootstatus "$IOS_SYNC_DEVICE" -b
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug \
  -destination "platform=iOS Simulator,id=$IOS_SYNC_DEVICE" -derivedDataPath "$IOS_SYNC_BUILD" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing
# Start after the potentially long first build so the five-minute pairing code stays fresh.
"$IOS_SYNC_TEMP/mac-fixture" "$IOS_SYNC_TEMP" "$IOS_SYNC_TEMP/pairing.txt" > "$IOS_SYNC_TEMP/server.log" 2>&1 &
IOS_SYNC_SERVER_PID=$!
IOS_SYNC_WAIT=0
while [ ! -s "$IOS_SYNC_TEMP/pairing.txt" ]; do
  kill -0 "$IOS_SYNC_SERVER_PID" 2>/dev/null || { printf 'Mac fixture failed to start\n'; exit 1; }
  IOS_SYNC_WAIT=$((IOS_SYNC_WAIT + 1))
  [ "$IOS_SYNC_WAIT" -lt 300 ] || { printf 'Mac fixture startup timed out\n'; exit 1; }
  sleep 0.1
done
xcrun simctl install "$IOS_SYNC_DEVICE" "$IOS_SYNC_BUILD/Build/Products/Debug-iphonesimulator/WiseNote.app"
IOS_SYNC_APP_DATA=$(xcrun simctl get_app_container "$IOS_SYNC_DEVICE" cloud.karama.wisenote data)
mkdir -p "$IOS_SYNC_APP_DATA/Documents"
cp "$IOS_SYNC_TEMP/pairing.txt" "$IOS_SYNC_APP_DATA/Documents/desktop-test-pairing.txt"
xcodebuild test-without-building -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug \
  -destination "platform=iOS Simulator,id=$IOS_SYNC_DEVICE" -derivedDataPath "$IOS_SYNC_BUILD" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  -parallel-testing-enabled NO \
  -only-testing:RingIntegrationTests/DesktopSyncIntegrationTests
