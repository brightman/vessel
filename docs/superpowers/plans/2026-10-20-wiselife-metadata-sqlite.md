# WiseLife SQLite Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Complete phase one of the approved architecture: durable SQLite metadata for audio notes, photo moments and reminders, preserving existing media and transfer behavior.

**Architecture:** Keep current repository interfaces and the single shared DaybookDatabase. Store searchable scalar columns and versioned Codable voice snapshots atomically; normalize photo attachments; persist reminders as rows. Import legacy JSON exactly once with transactional migration markers, retain legacy bytes, and use deletion tombstones to prevent orphan recovery from undoing user deletes.

**Tech Stack:** Swift, Foundation, system SQLite3; existing macOS CLI smoke tests and iOS simulator build.

## Global Constraints

- Work only in `/private/tmp/wiselife-sqlite-metadata-20261020`; original workspace has concurrent unrelated edits.
- Preserve audio/image paths, UUIDs, all VoiceNote fields, all PhotoMoment/PhotoAttachment fields, reminder notification IDs, Watch acknowledgment ordering and repository call sites.
- Real App roots use the existing shared database; arbitrary roots and tests are isolated. Never read user media, app containers, API secrets or real databases.
- Do not regenerate Xcode project, change Ring flag, change AI providers/UI, or add dependencies.
- Retain legacy JSON bytes; never reimport a completed domain or fall back to an empty repository on migration failure.
- SQL/file/notification side effects require failure compensation; publish in-memory values only after durable success.
- Migrate only phase one. Full text indexing, chunk coverage and cross-day AI belong to subsequent phases.

### Task 1: Migrate all three repositories with transactional recovery

**Files:**
- Modify: `apps/wrist-notes/Sources/iPhone/DaybookDatabase.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/NoteRepository.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/PhotoRepository.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/DaybookReminderPersistence.swift`
- Modify existing persistence smoke tests and their compile source lists where needed.
- Create: `apps/wrist-notes/Tests/MetadataSQLiteSmoke.swift`
- Create: `apps/wrist-notes/scripts/test_metadata_sqlite.sh`

**Interfaces:**
- Existing `init(root: URL)` remains valid; optional injected `DaybookDatabase` may be added.
- `DaybookDatabase.metadataURL(forRoot:)` compares standardized actual App roots against `VoiceNotes`, `PhotoMoments`, `DaybookReminders` under Documents; only exact matches route to `applicationURL`. Other roots use `root/metadata.sqlite3`.
- Existing `notes`, `moments`, `items`, import/update/delete/save/replace APIs retain semantics.
- Tables: `voice_notes`, `photo_moments`, `photo_attachments`, `daybook_reminders`, `media_tombstones`. Required columns/query contract: voice `id,captured_at,kind,title,transcript,summary,duration,audio_filename,payload`; photos `id,captured_at,caption,recognized_text`; attachments `id,moment_id,position,filename,recognized_text,recognition_error`; reminders `id,title,scheduled_at,source_id,status,notification_id,created_at,updated_at`; tombstones `kind,id,filename,deleted_at` with composite kind/id PK.
- Voice `payload` is complete Codable VoiceNote bytes; its indexed projection must match on read. Photo attachments have FK cascade and unique moment/position. Dates use Swift reference-date seconds.
- Add v2 schema transactionally while retaining v1 tables/indices and any semantic extension tables. A fresh DB receives both. Expose no test-only production switches.

- [x] **Step 1: Write and execute a failing migration behavior test before changing production.**

Use public repositories and actual temporary files. The first RED can use existing APIs only:

```swift
let root = temporary.appendingPathComponent("voice")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let note = VoiceNote(id: UUID(), kind: .thought, capturedAt: Date(timeIntervalSinceReferenceDate: 12345), duration: 12)
let oldBytes = try JSONEncoder().encode([note])
let json = root.appendingPathComponent("notes.json")
try oldBytes.write(to: json)
let repository = try NoteRepository(root: root)
try repository.update(id: note.id) { $0.title = "Edited after migration" }
expect(try Data(contentsOf: json) == oldBytes, "post-migration edits must not rewrite legacy JSON")
```

Compile with `swiftc Sources/Shared/VoiceNote.swift Sources/iPhone/DaybookDatabase.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/PhotoMoment.swift Sources/iPhone/PhotoRepository.swift Sources/iPhone/DaybookReminderPersistence.swift Tests/MetadataSQLiteSmoke.swift -o <temporary executable>` from app directory. Execute and retain exact RED evidence.

- [x] **Step 2: Implement schema and voice repository migration plus tests.**

Use existing `db.migrate(domain) { ... }` so completion marker and import share one transaction. CRUD reads current DB rows under `db.transaction`, changes only target rows, then reloads/publicizes after commit. Normal voice writes update scalar columns and Codable snapshot together. Validate UUIDs, finite dates and finite nonnegative duration, filename exactly `<UUID>.m4a`, path safety, duplicate IDs. Preserve optional speech/identity fields through Codable.

Test literal speaker names, segments, origin, messages, revisions, summary/states survive migration and reopen. Force failure using SQLite triggers, assert no partial row/marker and unchanged original bytes. Reopen after deletion with leftover media and verify tombstone suppresses orphan resurrection; retry file cleanup safely. Repeated UUID transfer has one row and can restore missing audio. Stale second instance must not overwrite independent first-instance edits.

- [x] **Step 3: Implement photo and reminder migration plus regression cases.**

Photo rows and ordered attachment rows commit together. Validate IDs/count/filenames and symlinks before using media. Keep old JSON untouched. Insert only new rows; targeted deletes use tombstones for file cleanup. Reminder replacement diffs compare baseline items with current rows before writes, reject stale updates without publishing; preserve coordinator compensating notification scheduling and IDs.

Tests cover multiple attachments and OCR errors, missing media with metadata intact, failed attachment insert after first insert, bad JSON then repaired retry, unrelated row preservation using a trigger, duplicate IDs, and coordinator failure compensation through an injected real SQLite write failure.

- [x] **Step 4: Repair affected existing test contracts and compile inputs.**

Existing tests that deliberately replace `notes.json`/`moments.json`/`reminders.json` with directories to simulate writes must use a real SQLite trigger instead; don't weaken the behavioral assertion. Every CLI source list compiling these repositories needs `DaybookDatabase.swift`. Add the new smoke suite to `test_local.sh` without changing concurrent ChatGPT-related lines. Preserve standalone speaker/voice pipeline tests as needed.

- [x] **Step 5: Verify and report.**

Run focused metadata, note, photo, reminder and SQLite suites. Assert `EXPLAIN QUERY PLAN` uses date indices for voice/photo/reminder ordered scans; preserve v1 data through schema upgrade and verify a future unsupported version is rejected. Record the exact tests and result. Self-review preservation/failure semantics and stage only task files in this isolated checkout; commit implementation for review. Save full report with RED/GREEN evidence and touched files at the controller-provided report path.

### Task 2: Integrate, build and document first-stage completion

**Files:** task-one files plus `apps/wrist-notes/docs/local-storage-and-retrieval.md` and a dated verification report.

**Interfaces:** consume task-one commit diff and test evidence; no API changes.

- [x] Review task one for spec compliance and correctness; resolve important findings and obtain scoped rereview.
- [x] Compare original-workspace file hashes with baseline; apply only task-owned changes, merging any concurrently changed compile script line by line.
- [x] Run focused tests from the integrated workspace and build the iPhone + embedded Watch simulator target with current project configuration. Do not install over a user's simulator data or access real app containers.
- [x] Update storage documentation to state actual SQLite primary stores, retained recovery JSON, migration/deletion behavior and unchanged future phases. Record test/build limitations precisely.
- [x] Run broad final review of this phase's diff and resolve findings; preserve unrelated changes and report remaining later phases.
