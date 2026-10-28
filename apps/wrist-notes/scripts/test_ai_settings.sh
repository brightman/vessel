#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-ai-settings.XXXXXX)
trap 'rm -rf "$output"' EXIT
chatgpt_sources="Sources/iPhone/ChatGPTProtocol.swift Sources/iPhone/ChatGPTIDToken.swift Sources/iPhone/ChatGPTAPI.swift Sources/iPhone/ChatGPTAccountStore.swift Sources/iPhone/ChatGPTAccountModel.swift"
swiftc $chatgpt_sources -module-cache-path "$output/cache" Sources/iPhone/AIConfiguration.swift Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/AppSettings.swift Sources/iPhone/CustomAISummarizer.swift Sources/iPhone/NearbyMacClient.swift Sources/iPhone/AISettingsModel.swift Sources/iPhone/KeychainSecretStore.swift Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/Shared/RecordingSessionFiles.swift Sources/Shared/RecordingAudioFile.swift Sources/Shared/RecordingDiagnostics.swift Sources/Shared/WatchSyncSnapshot.swift Sources/iPhone/PhoneWatchStatus.swift Tests/AISettingsSmoke.swift -o "$output/settings"
"$output/settings"
