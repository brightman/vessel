#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-assistant-voice.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/AssistantVoiceInputModel.swift Tests/AssistantVoiceInputSmoke.swift -o "$output/tests"
"$output/tests"
