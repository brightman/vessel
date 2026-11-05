#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /private/tmp/wiselife-capture-pool.XXXXXX)
trap 'rm -rf "$output"' EXIT
host_target="$(uname -m)-apple-macosx14.0"
clang_sanitizer=
swift_sanitizer=
if [ "${CAPTURE_TSAN:-0}" = 1 ]; then
  clang_sanitizer=-fsanitize=thread
  swift_sanitizer=-sanitize=thread
fi
xcrun clang -target "$host_target" -std=c11 -O2 -Wall -Wextra -Werror \
  $clang_sanitizer \
  -c Sources/Watch/RecordingAtomics/RecordingAtomics.c -o "$output/RecordingAtomics.o"
for test in CapturePoolRejectionSmoke CapturePoolConcurrencySmoke; do
swiftc -target "$host_target" -O -g -warnings-as-errors -module-cache-path "$output/cache" \
  $swift_sanitizer \
  -I Sources/Watch/RecordingAtomics "$output/RecordingAtomics.o" \
  Sources/Shared/CaptureMetadata.swift \
  Sources/Shared/VoiceNote.swift \
  Sources/Shared/RecordingSession.swift \
  Sources/Shared/RecordingSessionFiles.swift \
  Sources/Shared/RecordingAudioFile.swift \
  Sources/Shared/RecordingDiagnostics.swift \
  Sources/Shared/RecordingFramePartition.swift \
  Sources/Watch/SegmentedAudioCapture.swift \
  "Tests/$test.swift" \
  -o "$output/$test"
"$output/$test"
done
