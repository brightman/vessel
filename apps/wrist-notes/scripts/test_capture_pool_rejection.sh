#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-capture-pool.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" \
  Sources/Shared/CaptureMetadata.swift \
  Sources/Shared/VoiceNote.swift \
  Sources/Shared/RecordingSession.swift \
  Sources/Shared/RecordingSessionFiles.swift \
  Sources/Shared/RecordingAudioFile.swift \
  Sources/Shared/RecordingDiagnostics.swift \
  Sources/Shared/RecordingFramePartition.swift \
  Sources/Watch/SegmentedAudioCapture.swift \
  Tests/CapturePoolRejectionSmoke.swift \
  -o "$output/capture-pool"
"$output/capture-pool"
