#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-watch-handshake.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" \
  Sources/Shared/CaptureMetadata.swift \
  Sources/Shared/VoiceNote.swift \
  Sources/Shared/RecordingSession.swift \
  Sources/Shared/RecordingChunkProtocol.swift \
  Sources/Shared/RecordingAudioFile.swift \
  Sources/Shared/RecordingChunkTransport.swift \
  Sources/Watch/WatchChunkTransferQueue.swift \
  Tests/WatchChunkHandshakeSmoke.swift \
  -o "$output/handshake"
"$output/handshake"
