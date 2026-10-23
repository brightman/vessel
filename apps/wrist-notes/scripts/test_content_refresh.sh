#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-content-refresh.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -D CONTENT_SEGMENT_MODEL_TESTS -module-cache-path "$output/cache" \
  Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift \
  Sources/iPhone/AudioProcessing.swift Sources/iPhone/ContentSegmentation.swift Sources/iPhone/AudioWindowPlanner.swift \
  Sources/iPhone/PhotoMoment.swift Sources/iPhone/LifeSourceStore.swift Sources/iPhone/DaybookPlaces.swift \
  Sources/iPhone/ContentSegmentPresentation.swift Sources/iPhone/ContentSegmentModel.swift Sources/iPhone/AudioSpeakerMapping.swift \
  Sources/iPhone/AudioProcessingRepository.swift Sources/iPhone/ContentSegmentRepository.swift Sources/iPhone/ContentEnrichmentService.swift \
  Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift \
  Tests/ContentSegmentRefreshSmoke.swift -o "$output/refresh"
"$output/refresh"
