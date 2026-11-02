#!/bin/bash
# Real Apple local translation first, then the fixed retrieval benchmark.
set -euo pipefail
cd "$(dirname "$0")/.."
output=${1:?Usage: benchmark_apple_translation.sh NEW_OUTPUT_DIRECTORY}
mkdir -p "$output"
output=$(cd "$output" && pwd)
if [[ -e "$output/translated-queries.json" ]]; then
    echo 'Use a new output directory to preserve earlier translation results.' >&2
    exit 2
fi
build=$(mktemp -d /private/tmp/wiselife-apple-translation.XXXXXX)
trap 'rm -rf "$build"' EXIT
xcrun --sdk macosx swiftc -target arm64-apple-macos26.0 -parse-as-library -O \
    Sources/iPhone/DaybookQueryExpansion.swift Sources/iPhone/AppleQueryTranslator.swift \
    Tests/AppleQueryTranslationExperiment.swift -o "$build/translate"
"$build/translate" "$PWD/Tests/Fixtures/apple-embedding-bilingual-v1.json" \
    "$output/translated-queries.json" 2>"$output/translation.log"
WISELIFE_BENCH_TRANSLATIONS="$output/translated-queries.json" \
    bash scripts/benchmark_apple_embedding.sh macos "$output/retrieval"
shasum -a 256 Sources/iPhone/DaybookQueryExpansion.swift Sources/iPhone/AppleQueryTranslator.swift \
    Tests/AppleQueryTranslationExperiment.swift "$output/translated-queries.json" >"$output/translation-sha256.txt"
