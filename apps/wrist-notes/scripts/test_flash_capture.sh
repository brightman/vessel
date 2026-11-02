#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-flash.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" \
 Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift \
 Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift Sources/iPhone/ContentSegmentation.swift \
 Sources/iPhone/DaybookDatabase.swift Sources/iPhone/ActionItem.swift \
 Sources/iPhone/FlashCapture.swift Sources/iPhone/FlashCaptureRepository.swift \
 Tests/FlashCaptureSmoke.swift -o "$output/flash"
"$output/flash"
