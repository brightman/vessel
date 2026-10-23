# Content V2 simulator lab

This is an explicit development pilot for the shared `ContentSegmentationV2.swift` engine. The normal iPhone automatic processing scheduler has **not** been switched to this engine.

## Fixture and execution

- Work only in the cloned simulator named **WiseLife Content Lab**. The original simulator, physical phone, and original recording remain separate.
- `prepare_fixture.py` imports one real source, checks its audio SHA256, and imports successful timed ASR/VAD evidence with provenance. It refuses conflicting existing data. It does not run fresh ASR/VAD.
- `build_runner.py <temporary build directory>` compiles the shared Swift core for iOS Simulator. Run the emitted executable with `simctl spawn`, passing the existing preferences file, `input.json`, and the run directory as file paths.
- `Runner.swift` reads the configured Doubao credentials inside the simulator's keychain. Never print or export them. The runner accepts only the already authorized HTTPS provider/model, sends full text blocks, and saves request/response evidence outside the repository. Network processing is explicit, never triggered by app launch.
- A run directory keeps validated checkpoints and exact-prompt response caches. Preserve prior `output.json` before changing prompts. A changed request is recomputed; successful unchanged stages can resume.

## Publication and native reads

1. Build the native **workspace**, scheme `WristNotes`, using a simulator destination and `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) WISELIFE_CONTENT_LAB'`. This disables legacy automatic processing and automatic daily recaps in the lab build only.
2. Stop the app before installing or writing its database. An installation may change its data-container UUID. Run `relocate_container.py <report directory>` to back up and update this fixture's source/window/segment media paths.
3. Build `Publish.swift` with `build_publisher.sh <binary>`. Arguments: database path, input JSON, output JSON, model label, simulator UUID. Back up the app database first.
4. The publisher verifies source revision, complete ASR/VAD evidence, unique IDs, transcript ownership, frame bounds, original file hashes, manual history, and source conflicts. A short SQLite transaction publishes normal segment/range/presentation rows. A rejection leaves prior content intact.
5. Run `test_publication.py <publisher> <database> <input> <output> <device>` for eight checks against disposable database copies, including seven rejected unsafe inputs and a valid idempotent repeat.
6. Build `ReadSnapshot.swift` using `build_snapshot_reader.sh`. Arguments: database path, source key, output JSON. It exercises the actual SQLite snapshot and meaningful-only timeline projection. Compare its output before and after app restart.
7. `build_report.py <report directory>` creates a Markdown segment list and a local HTML listening preview from the validated Swift output. It performs no additional segmentation.

## Review limits

The native app reads the persisted pilot output. The development runner is the entry point for further strategy experiments; manual reprocessing in the app still uses the existing production scheduler. Source input/output, model calls, database reads, native build, media decoding, and visual UI/playback checks are distinct acceptance items. Record unverified items explicitly.
