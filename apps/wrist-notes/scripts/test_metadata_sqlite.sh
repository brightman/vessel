#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-metadata-tests.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/PhotoMoment.swift Sources/iPhone/PhotoRepository.swift Sources/iPhone/DaybookReminderPersistence.swift Tests/MetadataSQLiteSmoke.swift -o "$output/metadata"
"$output/metadata"
