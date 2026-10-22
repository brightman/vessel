#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-contacts.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Tests/SpeakerContactsSmoke.swift -o "$output/contacts"
"$output/contacts"
swiftc Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/SpeakerTranscript.swift Tests/SpeakerDiarizationSmoke.swift -o "$output/speakers"
"$output/speakers"
swiftc Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Tests/VoiceOwnerSmoke.swift -o "$output/owner"
"$output/owner"
