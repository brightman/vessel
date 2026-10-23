#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
node --test watch/tests/*.test.js
output=$(mktemp -d /private/tmp/wristnotes-huawei-checks.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" iphone/Sources/Shared/VoiceNote.swift iphone/Sources/iPhone/NoteRepository.swift iphone/Tests/NoteRepositorySmoke.swift -o "$output/store"
"$output/store"
swiftc -module-cache-path "$output/cache" iphone/Sources/Shared/VoiceNote.swift iphone/Tests/NoteEditingSmoke.swift -o "$output/edit"
"$output/edit"
swiftc -module-cache-path "$output/cache" iphone/Sources/Shared/VoiceNote.swift iphone/Sources/iPhone/NoteRepository.swift iphone/Sources/iPhone/HuaweiRecordingReceiver.swift iphone/Tests/HuaweiRecordingReceiverSmoke.swift -o "$output/receiver"
"$output/receiver"
