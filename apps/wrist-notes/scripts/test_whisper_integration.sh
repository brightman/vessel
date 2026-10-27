#!/bin/sh
# Optional macOS 26+ integration test: downloads ~80 MB of public model assets.
set -eu
app_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
package_root=$(mktemp -d /private/tmp/wristnotes-whisper-integration.XXXXXX)
model_root=${WRISTNOTES_TEST_MODEL_DIR:-/private/tmp/wristnotes-whisper-test-models}
trap 'rm -rf "$package_root"' EXIT
mkdir -p "$package_root/Sources/Smoke"
for source in TranscriptionConfiguration WhisperModelStore LocalTranscriptionService AppleSpeechReservationCoordinator AppleSpeechResources OnDeviceTranscriber; do
    cp "$app_root/Sources/iPhone/$source.swift" "$package_root/Sources/Smoke/"
done
cp "$app_root/Tests/WhisperIntegrationSmoke.swift" "$package_root/Sources/Smoke/"
cp "$app_root/Tests/Fixtures/whisper-jfk.wav" "$package_root/whisper-jfk.wav"
cat > "$package_root/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WhisperIntegration", platforms: [.macOS("26.0")], dependencies: [
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.18.0"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.6")
], targets: [.executableTarget(name: "Smoke", dependencies: [
    .product(name: "WhisperKit", package: "whisperkit"),
    .product(name: "Tokenizers", package: "swift-transformers"),
    .product(name: "Hub", package: "swift-transformers")
])])
SWIFT
swift build --package-path "$package_root" -c release
"$package_root/.build/release/Smoke" "$app_root/Sources/iPhone/WhisperModels.json" "$model_root" "$package_root/whisper-jfk.wav"
# Reopen installed assets in a fresh process with network sockets denied.
sandbox-exec -p '(version 1) (allow default) (deny network*)' \
	    "$package_root/.build/release/Smoke" "$app_root/Sources/iPhone/WhisperModels.json" "$model_root" "$package_root/whisper-jfk.wav" --offline
printf '%s\n' 'PASS: fresh-process Whisper inference with network denied'
