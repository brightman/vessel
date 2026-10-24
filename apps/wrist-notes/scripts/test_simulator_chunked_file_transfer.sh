#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-simulator-file-transfer.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Tests/SimulatorChunkedFileTransferSmoke.swift -o "$output/smoke"
"$output/smoke"
