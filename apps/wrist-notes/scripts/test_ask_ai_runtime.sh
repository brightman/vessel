#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-ask-ai-runtime.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" \
  Sources/Shared/RecordingSession.swift Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift \
  Sources/iPhone/ContentSegmentation.swift Sources/iPhone/ContentSegmentationV2.swift Sources/iPhone/ContentSegmentRepository.swift \
  Sources/iPhone/AudioProcessingRepository.swift Sources/iPhone/AudioSpeakerMapping.swift Sources/iPhone/ContentEnrichmentService.swift \
  Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/DayRecord.swift \
  Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift \
  Sources/iPhone/AskAIContext.swift Sources/iPhone/AskAIRuntimeStore.swift Tests/AskAIRuntimeSmoke.swift -o "$output/runtime"
"$output/runtime" "$@"
