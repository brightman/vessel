#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
title_output=$(mktemp -d /private/tmp/wiselife-title-tests.XXXXXX)
trap 'rm -rf "$title_output"' EXIT
swiftc -module-cache-path "$title_output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/RecordingFormat.swift Sources/Shared/VoiceNote.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Tests/RecordingTitlesSmoke.swift -o "$title_output/titles"
"$title_output/titles"
swiftc -module-cache-path "$title_output/cache" Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Tests/NoteEditingSmoke.swift -o "$title_output/editing"
"$title_output/editing"
