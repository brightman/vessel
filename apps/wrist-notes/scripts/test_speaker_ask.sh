#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-speaker-ask.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" \
  Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift \
  Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift Sources/iPhone/ContentSegmentation.swift \
  Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift \
  Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift \
  Tests/SpeakerAskRetrievalSmoke.swift -o "$output/speaker-ask"
"$output/speaker-ask" "$@"
