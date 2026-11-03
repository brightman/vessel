#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-notebook.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" \
 Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift \
 Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift Sources/iPhone/ContentSegmentation.swift \
 Sources/iPhone/DaybookDatabase.swift Sources/iPhone/ActionItem.swift \
 Sources/iPhone/FlashCapture.swift Sources/iPhone/FlashCaptureRepository.swift \
 Sources/iPhone/NotebookIdeas.swift Sources/iPhone/NotebookIdeaRepository.swift \
 Tests/NotebookLedgerSmoke.swift -o "$output/notebook"
"$output/notebook"
