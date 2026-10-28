#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-passcode.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -target arm64-apple-macos15.0 -module-cache-path "$output/cache" Sources/iPhone/AppPasscodeVault.swift Sources/iPhone/AppLockModel.swift Tests/AppPasscodeSmoke.swift -o "$output/passcode"
"$output/passcode"
swiftc -module-cache-path "$output/cache" Sources/Shared/VoiceNote.swift Sources/Shared/CaptureMetadata.swift Sources/Shared/RecordingSession.swift Sources/Shared/RecordingChunkProtocol.swift Sources/Watch/WatchConnectivityStatus.swift Sources/Watch/WatchRecordingLibrary.swift Tests/WatchLibrarySmoke.swift -o "$output/library"
"$output/library"
