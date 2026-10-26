#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
recap_output=$(mktemp -d /private/tmp/wiselife-recaps.XXXXXX)
trap 'rm -rf "$recap_output"' EXIT
swiftc -module-cache-path "$recap_output/cache" \
  Sources/Shared/CaptureMetadata.swift Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift \
  Sources/iPhone/DaybookRecap.swift Sources/iPhone/DaybookRecapStore.swift \
  Tests/DaybookRecapSmoke.swift -o "$recap_output/recaps"
"$recap_output/recaps"
swiftc -module-cache-path "$recap_output/cache" \
  Sources/Shared/CaptureMetadata.swift Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift \
  Sources/iPhone/ChatGPTProtocol.swift Sources/iPhone/ChatGPTIDToken.swift Sources/iPhone/ChatGPTAPI.swift \
  Sources/iPhone/ChatGPTAccountStore.swift Sources/iPhone/ChatGPTAccountModel.swift \
  Sources/iPhone/AIConfiguration.swift Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/AppSettings.swift \
  Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/CustomAISummarizer.swift Sources/iPhone/NearbyMacClient.swift \
  Sources/iPhone/DaybookRecap.swift Sources/iPhone/DaybookRecapStore.swift \
  Sources/iPhone/DaybookRecapService.swift Sources/iPhone/DaybookRecapModel.swift \
  Tests/DaybookRecapModelSmoke.swift -o "$recap_output/model"
"$recap_output/model"
swiftc -module-cache-path "$recap_output/cache" \
  Sources/Shared/CaptureMetadata.swift Sources/iPhone/DayRecord.swift \
  Sources/iPhone/ChatGPTProtocol.swift Sources/iPhone/ChatGPTIDToken.swift Sources/iPhone/ChatGPTAPI.swift \
  Sources/iPhone/ChatGPTAccountStore.swift Sources/iPhone/ChatGPTAccountModel.swift \
  Sources/iPhone/AIConfiguration.swift Sources/iPhone/KeychainSecretStore.swift Sources/iPhone/CustomAISummarizer.swift Sources/iPhone/NearbyMacClient.swift \
  Sources/iPhone/DaybookRecap.swift Sources/iPhone/DaybookRecapService.swift \
  Tests/DaybookRecapServiceSmoke.swift -o "$recap_output/service"
"$recap_output/service"
