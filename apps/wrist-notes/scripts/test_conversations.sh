#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-conversations.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -D DAYBOOK_ASSISTANT_MODEL_TESTS -module-cache-path "$output/cache" \
  Sources/iPhone/ChatGPTProtocol.swift Sources/iPhone/ChatGPTIDToken.swift Sources/iPhone/ChatGPTAPI.swift \
  Sources/iPhone/ChatGPTAccountStore.swift Sources/iPhone/ChatGPTAccountModel.swift \
  Sources/Shared/CaptureMetadata.swift Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookConversationStore.swift \
  Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookAssistantModel.swift Sources/iPhone/DaybookAnswerService.swift \
  Sources/iPhone/AIConfiguration.swift Sources/iPhone/AppSettings.swift Sources/iPhone/CustomAISummarizer.swift \
  Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/TranscriptionConfiguration.swift \
  Tests/DaybookRetrievalSmoke.swift -o "$output/conversations"
"$output/conversations"
