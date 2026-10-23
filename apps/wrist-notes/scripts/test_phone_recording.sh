#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-recording.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/iPhone/PhoneRecordingDraftStore.swift Sources/iPhone/PhoneRecordingSession.swift Tests/PhoneRecordingSessionTests.swift -o "$output/tests"
"$output/tests"
