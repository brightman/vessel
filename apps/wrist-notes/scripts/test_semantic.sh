#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wristnotes-semantic.XXXXXX)
trap 'rm -rf "$output"' EXIT
vendor=Vendor/SQLiteVector
for source in "$vendor"/src/*.c "$vendor"/Bridge.c; do
    clang -DSQLITE_CORE -I"$vendor/src" -I"$vendor/libs" -O2 -c "$source" -o "$output/$(basename "$source" .c).o"
done
swiftc Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/Shared/RecordingSessionFiles.swift Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift Sources/iPhone/AudioSpeakerMapping.swift Sources/iPhone/AudioProcessingRepository.swift Sources/iPhone/ContentSegmentation.swift Sources/iPhone/ContentSegmentationV2.swift Sources/iPhone/ContentSegmentRepository.swift Sources/iPhone/ContentEnrichmentService.swift Sources/iPhone/NoteRepository.swift -module-cache-path "$output/cache" -I "$vendor" Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookFullTextIndex.swift Sources/iPhone/DaybookTextChunks.swift Sources/iPhone/DaybookSemanticIndex.swift Sources/iPhone/AppleDaybookEmbedding.swift Sources/iPhone/DaybookQueryExpansion.swift Sources/iPhone/AppleQueryTranslator.swift Sources/iPhone/DaybookSemanticSearchModel.swift Tests/DaybookFullTextChunksSmoke.swift Tests/DaybookSemanticTranslationSmoke.swift Tests/DaybookSemanticSmoke.swift "$output"/*.o -lsqlite3 -o "$output/semantic"
"$output/semantic" "$@"
