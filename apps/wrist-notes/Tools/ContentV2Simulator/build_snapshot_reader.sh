#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
swiftc -module-cache-path /private/tmp/wiselife-content-v2-module-cache \
  Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift \
  Sources/iPhone/AudioProcessing.swift Sources/iPhone/ContentSegmentation.swift Sources/iPhone/AudioWindowPlanner.swift \
  Sources/iPhone/PhotoMoment.swift Sources/iPhone/LifeSourceStore.swift Sources/iPhone/DaybookPlaces.swift \
  Sources/iPhone/ContentSegmentPresentation.swift Sources/iPhone/ContentSegmentModel.swift Sources/iPhone/AudioSpeakerMapping.swift \
  Sources/iPhone/AudioProcessingRepository.swift Sources/iPhone/ContentSegmentRepository.swift Sources/iPhone/ContentEnrichmentService.swift \
  Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift \
  Tools/ContentV2Simulator/ReadSnapshot.swift -o "${1:?output binary path required}"
