#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-recording-presentation.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/Shared/RecordingChunkProtocol.swift Sources/Shared/RecordingAudioFile.swift Sources/Shared/RecordingChunkTransport.swift Sources/Shared/WatchSyncSnapshot.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/RecordingSessionRepository.swift Sources/iPhone/RecordingChunkReceiver.swift Sources/iPhone/WatchSyncStore.swift Sources/iPhone/RecordingSessionModel.swift Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/RecordingSessionPresentation.swift Sources/iPhone/RecordingRangePlayback.swift Tests/RecordingSessionPresentationSmoke.swift -o "$output/presentation"
"$output/presentation"
