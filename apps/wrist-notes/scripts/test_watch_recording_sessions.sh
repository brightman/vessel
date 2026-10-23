#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-watch-sessions.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift Sources/Shared/CaptureMetadata.swift Sources/Shared/RecordingSession.swift Sources/Shared/RecordingChunkProtocol.swift Sources/Shared/RecordingFramePartition.swift Sources/Shared/RecordingAudioFile.swift Sources/Shared/RecordingChunkTransport.swift Sources/Watch/WatchRecordingSessionStore.swift Tests/WatchRecordingSessionStoreSmoke.swift -o "$output/store"
"$output/store"
swiftc -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift Sources/Shared/CaptureMetadata.swift Sources/Shared/RecordingSession.swift Sources/Shared/RecordingChunkProtocol.swift Sources/Shared/RecordingFramePartition.swift Sources/Shared/RecordingAudioFile.swift Sources/Shared/RecordingChunkTransport.swift Sources/Watch/WatchRecordingSessionStore.swift Sources/Watch/SegmentedAudioCapture.swift Tests/SegmentedAudioCaptureSmoke.swift -o "$output/capture"
"$output/capture"
