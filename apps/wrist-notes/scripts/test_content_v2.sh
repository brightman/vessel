#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-content-v2.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/iPhone/ContentSegmentationV2.swift Tests/ContentSegmentationV2Smoke.swift -o "$output/content-v2"
swiftc -module-cache-path "$output/cache" Sources/iPhone/ContentSegmentationV2.swift Tests/ContentSegmentationV2ProductionSmoke.swift -o "$output/content-v2-production"
"$output/content-v2-production"
"$output/content-v2"
swiftc -module-cache-path "$output/cache" Sources/iPhone/ContentSegmentationV2.swift Tests/ContentSegmentationV2ProductionSmoke.swift -o "$output/content-v2-production"
"$output/content-v2-production"
