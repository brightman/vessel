#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wristnotes-semantic.XXXXXX)
trap 'rm -rf "$output"' EXIT
vendor=Vendor/SQLiteVector
for source in "$vendor"/src/*.c "$vendor"/Bridge.c; do
    clang -DSQLITE_CORE -I"$vendor/src" -I"$vendor/libs" -O2 -c "$source" -o "$output/$(basename "$source" .c).o"
done
swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" -I "$vendor" Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookFullTextIndex.swift Sources/iPhone/DaybookTextChunks.swift Sources/iPhone/DaybookSemanticIndex.swift Sources/iPhone/AppleDaybookEmbedding.swift Sources/iPhone/DaybookSemanticSearchModel.swift Tests/DaybookFullTextChunksSmoke.swift Tests/DaybookSemanticSmoke.swift "$output"/*.o -lsqlite3 -o "$output/semantic"
"$output/semantic"
