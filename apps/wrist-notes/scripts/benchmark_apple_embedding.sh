#!/bin/bash
# Read-only model experiment; no app install, personal records, downloads, or API calls.
set -euo pipefail
cd "$(dirname "$0")/.."
platform=${1:-macos}
output=${2:?Usage: benchmark_apple_embedding.sh macos|simulator OUTPUT_DIRECTORY [SIMULATOR_UDID]}
mkdir -p "$output"
output=$(cd "$output" && pwd)
build=$(mktemp -d /private/tmp/wiselife-embedding-benchmark.XXXXXX)
trap 'rm -rf "$build"' EXIT
vendor=Vendor/SQLiteVector
if [[ "$platform" == simulator ]]; then
    device=${3:?Simulator UDID is required}
    sdkname=iphonesimulator
    sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
    cflags=(-target arm64-apple-ios17.0-simulator -isysroot "$sdk")
    swiftflags=(-target arm64-apple-ios17.0-simulator -sdk "$sdk")
elif [[ "$platform" == macos ]]; then
    sdkname=macosx
    sdk=$(xcrun --sdk macosx --show-sdk-path)
    cflags=(-isysroot "$sdk")
    swiftflags=(-sdk "$sdk")
else
    echo 'Platform must be macos or simulator' >&2
    exit 2
fi
python3 - "$build/EmbeddingDeclarations.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/iPhone/DaybookSemanticIndex.swift').read_text()
start = source.index('struct DaybookEmbeddingSpace:')
end = source.index('private final class SemanticGeneration:')
Path(sys.argv[1]).write_text('import Foundation\n' + source[start:end])
PY
for source in "$vendor"/src/*.c "$vendor"/Bridge.c; do
    xcrun --sdk "$sdkname" clang "${cflags[@]}" -DSQLITE_CORE -I"$vendor/src" -I"$vendor/libs" -O2 -c "$source" -o "$build/$(basename "$source" .c).o"
done
xcrun --sdk "$sdkname" swiftc "${swiftflags[@]}" -O -module-cache-path "$build/cache" -I "$vendor" \
    "$build/EmbeddingDeclarations.swift" Sources/iPhone/AppleDaybookEmbedding.swift \
    Sources/iPhone/DaybookQueryExpansion.swift \
    Tests/AppleEmbeddingBilingualBenchmark.swift "$build"/*.o -lsqlite3 -o "$build/benchmark"
fixture="$PWD/Tests/Fixtures/apple-embedding-bilingual-v1.json"
arguments=("$fixture" "$output/results.json")
if [[ -n "${WISELIFE_BENCH_TRANSLATIONS:-}" ]]; then
    arguments+=("$WISELIFE_BENCH_TRANSLATIONS")
fi
if [[ "$platform" == simulator ]]; then
    xcrun simctl spawn "$device" "$build/benchmark" "${arguments[@]}" 2>"$output/run.log"
else
    "$build/benchmark" "${arguments[@]}" 2>"$output/run.log"
fi
shasum -a 256 "$fixture" Sources/iPhone/AppleDaybookEmbedding.swift Sources/iPhone/DaybookQueryExpansion.swift Tests/AppleEmbeddingBilingualBenchmark.swift >"$output/source-sha256.txt"
cat "$output/run.log"
