#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-places.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NotebookPlaces.swift Sources/iPhone/NotebookPlacesRepository.swift Tests/NotebookPlacesSmoke.swift -o "$output/places"
"$output/places"
if command -v xcrun >/dev/null 2>&1; then
  sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
  xcrun --sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios18.0-simulator -sdk "$sdk" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookStyle.swift Sources/iPhone/NotebookPlaces.swift Sources/iPhone/NotebookPlacesRepository.swift Sources/iPhone/NotebookPlacesView.swift
fi
