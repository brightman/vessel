#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-recording-transfer.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/Shared/RecordingChunkProtocol.swift Sources/Shared/RecordingAudioFile.swift Sources/Shared/RecordingChunkTransport.swift Sources/Shared/WatchSyncSnapshot.swift Sources/Watch/WatchChunkTransferQueue.swift Sources/Watch/WatchRecordingSessionStore.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/RecordingSessionRepository.swift Sources/iPhone/RecordingChunkReceiver.swift Sources/iPhone/WatchSyncStore.swift Tests/RecordingChunkTransferSmoke.swift -o "$output/transfer"
"$output/transfer"
