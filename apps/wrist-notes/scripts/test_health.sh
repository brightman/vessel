#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift Sources/iPhone/DayRecord.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/LifeSourceStore.swift Sources/iPhone/LifeSourceModel.swift Tests/HealthRefreshSmoke.swift -o "$output/health"
"$output/health"
