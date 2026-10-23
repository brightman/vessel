#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-coordinator.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift Sources/iPhone/AudioSpeakerMapping.swift Sources/iPhone/AudioProcessingRepository.swift Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/AudioProcessingCoordinator.swift Sources/iPhone/AudioAdaptiveInference.swift Tests/AudioProcessingCoordinatorSmoke.swift -o "$output/coordinator"
"$output/coordinator"
