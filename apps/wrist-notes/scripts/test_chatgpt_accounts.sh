#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-chatgpt-accounts.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/iPhone/AIConfiguration.swift Sources/iPhone/CustomAISummarizer.swift Sources/iPhone/ChatGPTSummarizer.swift Sources/iPhone/ChatGPTProtocol.swift Sources/iPhone/ChatGPTIDToken.swift Sources/iPhone/ChatGPTAPI.swift Sources/iPhone/ChatGPTAccountStore.swift Sources/iPhone/ChatGPTAccountModel.swift Tests/ChatGPTAccountSmoke.swift -o "$output/accounts"
"$output/accounts"
