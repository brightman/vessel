#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
route_output=$(mktemp -d /private/tmp/wiselife-ai-routing.XXXXXX)
trap 'rm -rf "$route_output"' EXIT
chatgpt_sources="Sources/iPhone/ChatGPTProtocol.swift Sources/iPhone/ChatGPTIDToken.swift Sources/iPhone/ChatGPTAPI.swift Sources/iPhone/ChatGPTAccountStore.swift Sources/iPhone/ChatGPTAccountModel.swift"
ai_sources="$chatgpt_sources Sources/iPhone/AIConfiguration.swift Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/AppSettings.swift Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/CustomAISummarizer.swift Sources/iPhone/ConfiguredAITextGenerator.swift Sources/iPhone/NearbyMacClient.swift"
swiftc $ai_sources -module-cache-path "$route_output/cache" Sources/iPhone/AISettingsModel.swift Sources/iPhone/PhoneWatchStatus.swift Tests/AISettingsSmoke.swift -o "$route_output/settings"
"$route_output/settings"
swiftc $ai_sources -D DAYBOOK_ASSISTANT_MODEL_TESTS -module-cache-path "$route_output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookAssistantModel.swift Sources/iPhone/DaybookAnswerService.swift Tests/DaybookRetrievalSmoke.swift -o "$route_output/answers"
"$route_output/answers"
swiftc $ai_sources -module-cache-path "$route_output/cache" Sources/Shared/CaptureMetadata.swift Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookPreferences.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookInsightStore.swift Sources/iPhone/DaybookInsightService.swift Sources/iPhone/DaybookInsightModel.swift Tests/DaybookInsightSmoke.swift -o "$route_output/insights"
"$route_output/insights"
swiftc -module-cache-path "$route_output/cache" Sources/Shared/CaptureMetadata.swift Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/LifeSourceStore.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookInsightStore.swift Tests/SQLitePersistenceSmoke.swift -o "$route_output/sqlite"
"$route_output/sqlite"
