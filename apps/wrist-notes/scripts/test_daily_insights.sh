#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
insight_output=$(mktemp -d /private/tmp/wiselife-insight-providers.XXXXXX)
trap 'rm -rf "$insight_output"' EXIT
insight_sources="Sources/Shared/CaptureMetadata.swift Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookPreferences.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookInsightStore.swift Sources/iPhone/DaybookInsightService.swift Sources/iPhone/DaybookInsightModel.swift Sources/iPhone/AIConfiguration.swift Sources/iPhone/AppSettings.swift Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/CustomAISummarizer.swift Sources/iPhone/ChatGPTProtocol.swift Sources/iPhone/ChatGPTIDToken.swift Sources/iPhone/ChatGPTAPI.swift Sources/iPhone/ChatGPTAccountStore.swift Sources/iPhone/ChatGPTAccountModel.swift"
swiftc -module-cache-path "$insight_output/cache" $insight_sources Tests/DaybookInsightRemoteSmoke.swift -o "$insight_output/remote"
"$insight_output/remote"
swiftc -module-cache-path "$insight_output/cache" $insight_sources Tests/DaybookInsightSmoke.swift -o "$insight_output/local"
"$insight_output/local"
swiftc -module-cache-path "$insight_output/cache" $insight_sources Tests/DaybookInsightServiceSmoke.swift -o "$insight_output/service"
"$insight_output/service"
swiftc -module-cache-path "$insight_output/cache" Sources/Shared/CaptureMetadata.swift Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/LifeSourceStore.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookInsightStore.swift Tests/SQLitePersistenceSmoke.swift -o "$insight_output/sqlite"
"$insight_output/sqlite"
