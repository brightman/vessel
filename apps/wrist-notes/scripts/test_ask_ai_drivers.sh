#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-ask-ai-drivers.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -whole-module-optimization -module-cache-path "$output/cache" \
  Sources/iPhone/ChatGPTProtocol.swift Sources/iPhone/ChatGPTIDToken.swift Sources/iPhone/ChatGPTAPI.swift \
  Sources/iPhone/ChatGPTAccountStore.swift Sources/iPhone/ChatGPTAccountModel.swift \
  Sources/Shared/RecordingSession.swift Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift \
  Sources/iPhone/ContentSegmentation.swift Sources/iPhone/ContentSegmentationV2.swift Sources/iPhone/ContentSegmentRepository.swift \
  Sources/iPhone/AudioProcessingRepository.swift Sources/iPhone/AudioSpeakerMapping.swift Sources/iPhone/ContentEnrichmentService.swift \
  Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookConversationStore.swift \
  Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/AskAIContext.swift Sources/iPhone/AskAIRuntimeStore.swift Sources/iPhone/AskAIReadTools.swift Sources/iPhone/AskAIRuntime.swift Sources/iPhone/AskAIAppleDriver.swift Sources/iPhone/AskAICustomDriver.swift Sources/iPhone/DaybookAnswerService.swift \
  Sources/iPhone/AIConfiguration.swift Sources/iPhone/AppSettings.swift Sources/iPhone/CustomAISummarizer.swift Sources/iPhone/NearbyMacClient.swift \
  Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/TranscriptionConfiguration.swift \
  Tests/AskAIDriversSmoke.swift -o "$output/drivers"
"$output/drivers" "$@"
