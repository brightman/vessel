#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-recording-repository.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/Shared/RecordingChunkProtocol.swift Sources/Shared/RecordingAudioFile.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/RecordingSessionRepository.swift Tests/RecordingSessionRepositorySmoke.swift -o "$output/repository"
"$output/repository"
