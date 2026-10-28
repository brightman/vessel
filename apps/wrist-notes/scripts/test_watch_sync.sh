#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-watch-sync.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/Shared/RecordingSessionFiles.swift Sources/Shared/RecordingAudioFile.swift Sources/Shared/RecordingDiagnostics.swift Sources/Shared/WatchSyncSnapshot.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/WatchSyncStore.swift Sources/iPhone/PhoneWatchStatus.swift Tests/WatchSyncSmoke.swift -o "$output/sync"
"$output/sync"
