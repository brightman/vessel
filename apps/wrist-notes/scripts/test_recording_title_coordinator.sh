#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-title-coordinator.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" \
  Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift \
  Sources/iPhone/ChatGPTProtocol.swift Sources/iPhone/ChatGPTIDToken.swift Sources/iPhone/ChatGPTAPI.swift \
  Sources/iPhone/ChatGPTAccountStore.swift Sources/iPhone/ChatGPTAccountModel.swift \
  Sources/iPhone/AIConfiguration.swift Sources/iPhone/TranscriptionConfiguration.swift \
  Sources/iPhone/AppSettings.swift Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/CustomAISummarizer.swift \
  Sources/iPhone/RecordingTitleCoordinator.swift Tests/RecordingTitleCoordinatorSmoke.swift -o "$output/titles"
"$output/titles"
