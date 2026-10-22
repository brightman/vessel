#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output=$(mktemp -d /private/tmp/wiselife-life-regressions.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/LifeSourceStore.swift Tests/LifeSourceSmoke.swift -o "$output/life-sources"
"$output/life-sources"
swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/iPhone/DayRecord.swift Sources/iPhone/LifeSourceStore.swift Sources/iPhone/LifeSourceModel.swift Sources/iPhone/DaybookPreferences.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Tests/LifeSourceModelSmoke.swift -o "$output/life-source-model"
"$output/life-source-model"
swiftc Sources/Shared/CaptureMetadata.swift -module-cache-path "$output/cache" Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/LifeSourceStore.swift Sources/iPhone/DaybookConversationStore.swift Sources/iPhone/DaybookRetrieval.swift Sources/iPhone/DaybookInsightStore.swift Tests/SQLitePersistenceSmoke.swift -o "$output/sqlite"
"$output/sqlite"
