#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-recording-locations.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" \
  Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift \
  Sources/Shared/RecordingChunkProtocol.swift Sources/Shared/RecordingAudioFile.swift Sources/Shared/RecordingChunkTransport.swift \
  Sources/Shared/RecordingFramePartition.swift Sources/Watch/SegmentedAudioCapture.swift \
  Sources/Watch/WatchRecordingSessionStore.swift Sources/Watch/WatchChunkTransferQueue.swift \
  Sources/iPhone/DaybookDatabase.swift Sources/iPhone/RecordingSessionRepository.swift Sources/iPhone/RecordingChunkReceiver.swift \
  Tests/RecordingLocationsSmoke.swift -o "$output/locations"
"$output/locations"
