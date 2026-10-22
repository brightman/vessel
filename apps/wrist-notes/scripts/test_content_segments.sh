#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-content-segments.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift Sources/iPhone/AudioSpeakerMapping.swift Sources/iPhone/AudioProcessingRepository.swift Sources/iPhone/ContentSegmentation.swift Sources/iPhone/ContentSegmentRepository.swift Sources/iPhone/ContentEnrichmentService.swift Tests/ContentSegmentationSmoke.swift -o "$output/segments"
"$output/segments"
