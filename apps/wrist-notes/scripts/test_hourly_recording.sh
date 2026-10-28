#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-hourly-check.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" \
  Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift \
  Sources/Shared/RecordingSession.swift Sources/Shared/RecordingSessionFiles.swift \
  Sources/Shared/RecordingFramePartition.swift Sources/Shared/RecordingAudioFile.swift \
  Sources/Shared/RecordingDiagnostics.swift Sources/Watch/SegmentedAudioCapture.swift \
  Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift \
  Sources/iPhone/RecordingSessionRepository.swift Tests/HourlyRecordingVerification.swift \
  -o "$output/hourly"
"$output/hourly"
