#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-places-tests.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/PhotoMoment.swift Sources/iPhone/PhotoRepository.swift Sources/Watch/WatchConnectivityStatus.swift Sources/iPhone/PhoneRecordingDraftStore.swift Tests/CaptureMetadataSmoke.swift -o "$output/places"
"$output/places"
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/CaptureLocationService.swift Tests/CaptureLocationLifecycleSmoke.swift -o "$output/lifecycle"
"$output/lifecycle"
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/iPhone/PhotoMetadataReader.swift Tests/PhotoMetadataSmoke.swift -o "$output/photos"
"$output/photos"
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/iPhone/PhotoMoment.swift Sources/iPhone/DayRecord.swift Sources/iPhone/LifeSourceStore.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookPlaces.swift Tests/DaybookPlacesSmoke.swift -o "$output/projection"
"$output/projection"
