#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-query-translation.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc Sources/iPhone/DaybookQueryExpansion.swift Tests/LocalQueryTranslationSmoke.swift -o "$output/translation-policy"
"$output/translation-policy"
