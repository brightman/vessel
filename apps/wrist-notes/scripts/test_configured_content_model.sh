#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-configured-content.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift Sources/iPhone/ContentSegmentation.swift Sources/iPhone/ContentEnrichmentService.swift Sources/iPhone/AIConfiguration.swift Sources/iPhone/CustomAISummarizer.swift Sources/iPhone/NearbyMacClient.swift Sources/iPhone/ConfiguredContentTextModel.swift Tests/ConfiguredContentModelSmoke.swift -o "$output/model"
"$output/model"
