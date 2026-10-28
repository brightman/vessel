#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-recording-addresses.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift \
  Sources/Shared/RecordingSession.swift Sources/Shared/RecordingSessionFiles.swift Sources/Shared/RecordingAudioFile.swift \
  Sources/iPhone/DaybookDatabase.swift Sources/iPhone/RecordingSessionRepository.swift \
  Sources/Shared/RecordingDiagnostics.swift Sources/iPhone/CaptureAddressModel.swift Sources/iPhone/RecordingLocationAddressModel.swift \
  Tests/RecordingLocationAddressesSmoke.swift -o "$output/addresses"
"$output/addresses"
