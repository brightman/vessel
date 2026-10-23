#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-bounded-audio.XXXXXX)
trap 'rm -rf "$output"' EXIT
shared="Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Sources/Shared/RecordingSession.swift Sources/iPhone/AudioProcessing.swift Sources/iPhone/AudioWindowPlanner.swift"
swiftc -module-cache-path "$output/cache" $shared Sources/iPhone/BoundedAudioReader.swift Tests/BoundedAudioReaderSmoke.swift -o "$output/reader"
"$output/reader"
swiftc -module-cache-path "$output/cache" $shared Sources/iPhone/BoundedAudioReader.swift Sources/iPhone/TranscriptionConfiguration.swift Sources/iPhone/WhisperModelStore.swift Sources/iPhone/SpeakerModelStore.swift Sources/iPhone/OnDeviceSpeechActivity.swift Sources/iPhone/AudioSpeakerMapping.swift Tests/AudioActivitySmoke.swift -o "$output/activity"
"$output/activity"
swiftc -module-cache-path "$output/cache" Sources/iPhone/LocalAudioInferenceGate.swift Tests/AudioInferenceGateSmoke.swift -o "$output/gate"
"$output/gate"
