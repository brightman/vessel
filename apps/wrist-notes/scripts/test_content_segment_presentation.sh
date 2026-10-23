#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-content-presentation.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/iPhone/AudioProcessing.swift Sources/iPhone/ContentSegmentation.swift Sources/iPhone/AudioWindowPlanner.swift Sources/iPhone/PhotoMoment.swift Sources/iPhone/LifeSourceStore.swift Sources/iPhone/DaybookPlaces.swift Sources/iPhone/ContentSegmentPresentation.swift Sources/iPhone/ContentSegmentModel.swift Sources/iPhone/AudioSpeakerMapping.swift Sources/iPhone/AudioProcessingRepository.swift Sources/iPhone/ContentSegmentRepository.swift Sources/iPhone/ContentEnrichmentService.swift Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookConversationStore.swift Tests/ContentSegmentPresentationSmoke.swift -o "$output/presentation"
"$output/presentation" "$@"

chatgpt_sources="Sources/iPhone/ChatGPTProtocol.swift Sources/iPhone/ChatGPTIDToken.swift Sources/iPhone/ChatGPTAPI.swift Sources/iPhone/ChatGPTAccountStore.swift Sources/iPhone/ChatGPTAccountModel.swift"
swiftc Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift $chatgpt_sources -D DAYBOOK_ASSISTANT_MODEL_TESTS -module-cache-path "$output/cache" Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookAssistantModel.swift Sources/iPhone/DaybookAnswerService.swift Sources/iPhone/AIConfiguration.swift Sources/iPhone/AppSettings.swift Sources/iPhone/CustomAISummarizer.swift Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/TranscriptionConfiguration.swift Tests/DaybookRetrievalSmoke.swift -o "$output/assistant"
"$output/assistant"
