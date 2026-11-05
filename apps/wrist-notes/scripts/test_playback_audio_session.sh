#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-playback-session.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/iPhone/PlaybackAudioSession.swift Tests/PlaybackAudioSessionSmoke.swift -o "$output/playback"
"$output/playback"
swiftc -module-cache-path "$output/cache" Sources/iPhone/PlaybackAudioSession.swift Sources/iPhone/AudioPlayback.swift Tests/PlaybackFileTransportSmoke.swift -o "$output/file-playback"
"$output/file-playback"
