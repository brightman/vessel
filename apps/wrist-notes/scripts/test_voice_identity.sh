#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wristnotes-voice.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library Sources/iPhone/VoiceIdentity.swift Tests/VoiceIdentitySmoke.swift -o "$output/policy"
"$output/policy"
if [ "${VOICE_IDENTITY_REAL_MODEL:-0}" = 1 ]; then
    swiftc -parse-as-library Sources/iPhone/VoiceIdentity.swift Sources/iPhone/WhisperModelStore.swift Sources/iPhone/VoiceIdentityModelStore.swift Sources/iPhone/VoiceEmbeddingEngine.swift Tests/VoiceIdentityInferenceSmoke.swift -o "$output/inference"
    "$output/inference" "${VOICE_IDENTITY_MODEL_ROOT:-/private/tmp/wiselife-identity-installed}" Sources/iPhone/VoiceIdentityModels.json
fi
