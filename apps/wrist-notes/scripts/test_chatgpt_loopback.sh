#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
chatgpt_output=$(mktemp -d /private/tmp/chatgpt-loopback.XXXXXX)
trap 'rm -rf "$chatgpt_output"' EXIT
swiftc -swift-version 6 -module-cache-path "$chatgpt_output/cache" Sources/iPhone/ChatGPTLoopback.swift Tests/ChatGPTLoopbackSmoke.swift -o "$chatgpt_output/loopback"
"$chatgpt_output/loopback"
chatgpt_sdk=$(xcrun --show-sdk-path --sdk iphonesimulator)
xcrun swiftc -swift-version 6 -typecheck -module-cache-path "$chatgpt_output/ios-cache" -sdk "$chatgpt_sdk" -target arm64-apple-ios18.0-simulator Sources/iPhone/ChatGPTProtocol.swift Sources/iPhone/ChatGPTLoopback.swift Sources/iPhone/ChatGPTBrowserAuthorization.swift
printf '%s\n' 'ChatGPT browser adapter iOS typecheck passed'
