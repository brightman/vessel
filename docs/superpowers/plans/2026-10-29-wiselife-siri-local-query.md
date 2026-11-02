# WiseLife Siri 本地查询 Implementation Plan

> **For agentic workers:** Implement this plan inline with test-first checkpoints. Keep each change limited to WiseLife Siri queries.

**Goal:** Add a Siri App Intent that answers questions from WiseLife's local records without exporting full transcripts to Spotlight or calling a remote model.

**Architecture:** Reuse `DaybookRetrieval` and `DaybookAnswerService` with an explicitly local `AIConfiguration`. Load records directly from the local `NoteRepository` when Siri runs. Keep the feature in the existing iPhone intent source file to avoid broad Xcode project regeneration.

**Tech Stack:** Swift, App Intents, Foundation Models, existing SQLite repositories, current smoke-test scripts.

## Global Constraints

- iOS deployment target remains 26.0.
- No full-text `IndexedEntity` / Spotlight indexing in this iteration.
- No remote AI, network calls, new persistent query history, or transcript logging from Siri.
- Respect the user's AI source permission for voice and thought records.
- Preserve existing recording intents and user worktree changes.

---

### Task 1: Verify retrieval behavior for Siri-style questions

**Files:**
- Test: `apps/wrist-notes/Tests/SiriRecordQuerySmoke.swift`
- Test runner: `apps/wrist-notes/scripts/test_siri_record_query.sh`

**Interfaces:**
- Reuse the production `DaybookRetrieval.prepare(question:records:selectedDate:automatic:expanded:)` contract.
- Verify question date resolution, keyword filtering, and source IDs using real in-memory `DayRecord` values.

- [ ] Add a smoke test for yesterday-plus-keyword returning only the matching record and no unrelated source IDs.
- [ ] Run it and verify it fails because the Siri query adapter is not yet available.
- [ ] Add the minimal testable adapter and verify the test passes.

### Task 2: Add the local-only App Intent

**Files:**
- Modify: `apps/wrist-notes/Sources/iPhone/RecordingIntents.swift`

**Interfaces:**
- Add `AskWiseLifeRecordsIntent` with a bounded free-form `question` parameter.
- Provide an App Shortcut phrase and dialog response.
- Load local notes, build records, prepare cited evidence, and call the local-only answer path.

- [ ] Add no-data, invalid-question, model-unavailable, and successful-answer outcomes.
- [ ] Keep existing recording shortcuts unchanged.
- [ ] Compile the iOS Simulator target and run focused smoke verification.

### Task 3: Final verification

**Files:**
- Review: `apps/wrist-notes/Sources/iPhone/RecordingIntents.swift`
- Review: `apps/wrist-notes/Tests/SiriRecordQuerySmoke.swift`

- [ ] Run the focused Siri query test script.
- [ ] Run the existing local regression script if its preconditions are available.
- [ ] Build the iOS Simulator app and report that Siri device invocation still needs a physical/Siri runtime check if not available locally.
