#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-location-movements.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -module-cache-path "$output/cache" Sources/Shared/CaptureMetadata.swift \
  Sources/iPhone/DayRecord.swift Sources/iPhone/CaptureAddressModel.swift \
  Sources/iPhone/LocationMovementBuilder.swift Tests/LocationMovementSmoke.swift -o "$output/movements"
"$output/movements"
