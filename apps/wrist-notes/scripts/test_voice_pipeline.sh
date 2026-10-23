#!/bin/sh
# macOS 26 + Xcode Swift tools, installed say voices Samantha/Daniel, ffmpeg.
# Existing verified models (no model downloads):
#   scripts/test_voice_pipeline.sh /path/to/SpeakerModels /path/to/Models
# Explicitly allow public model downloads into those roots:
#   VOICE_PIPELINE_DOWNLOAD_MODELS=1 scripts/test_voice_pipeline.sh speaker-root identity-root
# Optional VOICE_PIPELINE_WORK_DIR retains/reuses this script's isolated package,
# fixtures, build cache and results. Default creates a retained temporary directory.
set -eu
[ "$#" = 2 ] || { echo "usage: $0 speaker-model-root identity-model-root" >&2; exit 2; }
command -v swift >/dev/null
command -v say >/dev/null
command -v ffmpeg >/dev/null
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
mkdir -p "$1" "$2"
speaker_root=$(CDPATH= cd -- "$1" && pwd)
identity_root=$(CDPATH= cd -- "$2" && pwd)
work=${VOICE_PIPELINE_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/wristnotes-voice-pipeline.XXXXXX")}
mkdir -p "$work"
work=$(CDPATH= cd -- "$work" && pwd)
package="$work/package"
mkdir -p "$package/Sources/Smoke" "$work/fixtures"
echo "Voice pipeline artifacts: $work"
cat > "$package/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "VoicePipelineVerification", platforms: [.macOS("26.0")], dependencies: [
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "0.18.0"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.6"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    .package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.3"),
    .package(url: "https://github.com/huggingface/swift-jinja.git", exact: "2.5.2")
], targets: [.executableTarget(name: "Smoke", dependencies: [
    .product(name: "WhisperKit", package: "argmax-oss-swift"),
    .product(name: "SpeakerKit", package: "argmax-oss-swift"),
    .product(name: "Tokenizers", package: "swift-transformers"),
    .product(name: "Hub", package: "swift-transformers")
])])
PACKAGE
for name in AppleSpeechReservationCoordinator AppleSpeechResources LocalTranscriptionService LocalAudioInferenceGate BoundedAudioReader OnDeviceSpeechActivity AudioSpeakerMapping AudioProcessing AudioAdaptiveInference AudioWindowPlanner OfflineWhisperTokenizer OnDeviceTranscriber SpeakerModelStore SpeakerTranscript TranscriptionConfiguration WhisperModelStore VoiceIdentity VoiceEmbeddingEngine VoiceIdentityModelStore VoiceSpeechSelection; do
    cp "$repo/Sources/iPhone/$name.swift" "$package/Sources/Smoke/$name.swift"
done
cp "$repo/Sources/Shared/VoiceNote.swift" "$package/Sources/Smoke/VoiceNote.swift"
cp "$repo/Sources/Shared/CaptureMetadata.swift" "$package/Sources/Smoke/CaptureMetadata.swift"
cp "$repo/Sources/Shared/RecordingSession.swift" "$package/Sources/Smoke/RecordingSession.swift"
cp "$repo/Tests/VoiceIdentityPipelineSmoke.swift" "$package/Sources/Smoke/VoiceIdentityPipelineSmoke.swift"
cat > "$work/fixtures/enrollment.txt" <<'TEXT'
Today I am recording a sample of my own voice. I want to remember the important things that happen during an ordinary day. This morning I walked through the park and listened to the birds singing in the trees. Later I met a friend for coffee and we talked about our plans for next month. We might visit the coast and explore a few small towns along the way. At work I finished reading a useful report and wrote down several questions for our next meeting. In the evening I will cook dinner, read a book, and take a little time to plan tomorrow. I enjoy learning new ideas and keeping a clear record of what matters most to me.
TEXT
cat > "$work/fixtures/query.txt" <<'TEXT'
The weather should be clear tomorrow, so I would like to spend some time outdoors. Please remind me to bring a notebook and a bottle of water. I have been thinking about how to make better decisions and keep track of the small details that are easy to forget. Reading and conversation often help me understand a difficult problem. Later this week I will visit the library and look for a few interesting books. When I get home I plan to review my notes and write down what I learned.
TEXT
for voice in Samantha Daniel; do
    mkdir -p "$work/fixtures/$voice"
    for text in enrollment query; do
        say -v "$voice" -r 180 -f "$work/fixtures/$text.txt" -o "$work/fixtures/$voice/$text.aiff"
        ffmpeg -v error -y -i "$work/fixtures/$voice/$text.aiff" -ar 16000 -ac 1 "$work/fixtures/$voice/$text.wav"
    done
done
ffmpeg -v error -y -i "$work/fixtures/Samantha/query.wav" -i "$work/fixtures/Daniel/query.wav" -filter_complex '[0:a][1:a]concat=n=2:v=0:a=1[out]' -map '[out]' "$work/fixtures/mixed.wav"
swift build --package-path "$package" -c release --jobs "${VOICE_PIPELINE_JOBS:-4}"
for voice in Samantha Daniel; do
    case "$voice" in Samantha) other=Daniel ;; Daniel) other=Samantha ;; esac
    fixture="$work/fixtures/$voice"
    cp "$fixture/enrollment.wav" "$fixture/enroll.wav"
    cp "$fixture/query.wav" "$fixture/same.wav"
    cp "$work/fixtures/$other/query.wav" "$fixture/other.wav"
    cp "$work/fixtures/mixed.wav" "$fixture/mixed.wav"
    "$package/.build/release/Smoke" "$repo/Sources/iPhone" "$speaker_root" "$identity_root" "$fixture" "$work/$voice-results.txt"
done
echo "Both synthetic voice pipelines passed. Reports: $work/Samantha-results.txt and $work/Daniel-results.txt"
