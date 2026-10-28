#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-source-discovery.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/Shared/RecordingSessionFiles.swift Sources/Shared/RecordingAudioFile.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/RecordingSessionRepository.swift Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift Sources/iPhone/AudioSpeakerMapping.swift Sources/iPhone/AudioProcessingRepository.swift Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/AudioProcessingCoordinator.swift Sources/iPhone/AudioSourceDiscovery.swift Tests/AudioSourceDiscoverySmoke.swift -o "$output/discovery"
"$output/discovery"
