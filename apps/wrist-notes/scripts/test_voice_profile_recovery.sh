#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-profile-recovery.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift \
  Sources/iPhone/SpeakerTranscript.swift Sources/iPhone/VoiceSpeechSelection.swift \
  Sources/iPhone/VoiceIdentity.swift Sources/iPhone/MyVoiceProfileModel.swift \
  Tests/MyVoiceProfileRecoverySmoke.swift -o "$output/check"
"$output/check"
