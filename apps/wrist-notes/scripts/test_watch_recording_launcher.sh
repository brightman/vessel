#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-watch-launcher.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/WatchRecordingShared/WatchRecordingLink.swift Sources/Watch/WatchRecordingLauncher.swift Tests/WatchRecordingLauncherSmoke.swift -o "$output/launcher"
"$output/launcher"
swiftc -module-cache-path "$output/cache" Sources/Watch/RecordingButtonInteraction.swift Tests/RecordingButtonInteractionSmoke.swift -o "$output/interaction"
"$output/interaction"
