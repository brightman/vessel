#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -module-cache-path "$output/cache" Sources/iPhone/ChatGPTProtocol.swift Sources/iPhone/ChatGPTIDToken.swift Sources/iPhone/ChatGPTAPI.swift Tests/ChatGPTProtocolSmoke.swift -o "$output/chatgpt-protocol"
"$output/chatgpt-protocol"
