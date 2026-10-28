#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-recording-sessions.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift Sources/Shared/CaptureMetadata.swift Sources/Shared/RecordingSession.swift Sources/Shared/RecordingSessionFiles.swift Sources/Shared/RecordingFramePartition.swift Tests/RecordingSessionSmoke.swift -o "$output/sessions"
"$output/sessions"

sh scripts/test_recording_repository.sh
sh scripts/test_recording_presentation.sh
