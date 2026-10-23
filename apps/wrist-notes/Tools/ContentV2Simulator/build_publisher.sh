#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
swiftc -module-cache-path /private/tmp/wiselife-content-v2-module-cache \
  Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift \
  Sources/iPhone/DaybookDatabase.swift Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift \
  Sources/iPhone/AudioSpeakerMapping.swift Sources/iPhone/AudioProcessingRepository.swift \
  Sources/iPhone/ContentSegmentation.swift Sources/iPhone/ContentSegmentationV2.swift \
  Tools/ContentV2Simulator/Publish.swift -o "${1:?output binary path required}"
