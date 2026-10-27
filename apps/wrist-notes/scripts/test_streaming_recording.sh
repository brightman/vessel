#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-streaming.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" \
  Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift \
  Sources/Shared/RecordingChunkProtocol.swift Sources/Shared/RecordingFramePartition.swift Sources/Shared/RecordingAudioFile.swift \
  Sources/Shared/RecordingChunkTransport.swift Sources/Watch/SegmentedAudioCapture.swift \
  Sources/Watch/WatchRecordingSessionStore.swift Sources/Watch/WatchChunkTransferQueue.swift \
  Sources/iPhone/DaybookDatabase.swift Sources/iPhone/RecordingSessionRepository.swift Sources/iPhone/RecordingChunkReceiver.swift \
  Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift Sources/iPhone/AudioSpeakerMapping.swift \
  Sources/iPhone/AudioProcessingRepository.swift Sources/iPhone/TranscriptionConfiguration.swift \
  Sources/iPhone/AudioProcessingCoordinator.swift Sources/iPhone/ContentSegmentation.swift \
  Sources/iPhone/ContentSegmentationV2.swift Sources/iPhone/ContentSegmentRepository.swift Sources/iPhone/ContentEnrichmentService.swift \
  Sources/iPhone/BoundedAudioReader.swift Tests/StreamingRecordingSmoke.swift -o "$output/streaming"
"$output/streaming"
