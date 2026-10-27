#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-apple-asr-policy.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/iPhone/TranscriptionConfiguration.swift Tests/AppleASREnginePolicySmoke.swift -o "$output/policy"
"$output/policy"
