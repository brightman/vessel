#!/bin/sh
set -eu
SYNC_REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$SYNC_REPO_ROOT"
SYNC_TEST_ROOT=$(mktemp -d /private/tmp/wiselife-desktop-tests.XXXXXX)
SYNC_FIXTURE_PID=''
trap 'if [ -n "$SYNC_FIXTURE_PID" ]; then kill "$SYNC_FIXTURE_PID" 2>/dev/null || true; fi; rm -rf "$SYNC_TEST_ROOT"' EXIT INT TERM
python3 desktop/Tests/model_fixture.py "$SYNC_TEST_ROOT/port" &
SYNC_FIXTURE_PID=$!
while [ ! -s "$SYNC_TEST_ROOT/port" ]; do sleep 0.1; done
export WISELIFE_TEST_MODEL_PORT=$(cat "$SYNC_TEST_ROOT/port")
swiftc -swift-version 5 -module-cache-path "$SYNC_TEST_ROOT/cache" \
  desktop/Shared/*.swift desktop/Sources/Core/*.swift \
  apps/wrist-notes/Sources/Shared/CaptureMetadata.swift \
  apps/wrist-notes/Sources/Shared/VoiceNote.swift \
  apps/wrist-notes/Sources/Shared/RecordingSession.swift \
  apps/wrist-notes/Sources/iPhone/DaybookDatabase.swift \
  apps/wrist-notes/Sources/iPhone/AudioProcessing.swift \
  apps/wrist-notes/Sources/iPhone/AudioWindowPlanner.swift \
  apps/wrist-notes/Sources/iPhone/AudioSpeakerMapping.swift \
  apps/wrist-notes/Sources/iPhone/AudioProcessingRepository.swift \
  apps/wrist-notes/Sources/iPhone/PhoneDesktopSyncRepository.swift \
  desktop/Tests/SyncIntegrationSmoke.swift -o "$SYNC_TEST_ROOT/sync-tests"
"$SYNC_TEST_ROOT/sync-tests"
