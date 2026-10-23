#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-address-tests.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/PhotoMoment.swift Sources/iPhone/PhotoRepository.swift Tests/CaptureAddressPersistenceSmoke.swift -o "$output/persistence"
"$output/persistence"
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/iPhone/CaptureAddressModel.swift Tests/CaptureAddressModelSmoke.swift -o "$output/model"
"$output/model"
