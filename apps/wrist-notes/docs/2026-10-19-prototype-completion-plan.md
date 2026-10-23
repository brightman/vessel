# WiseLife prototype completion implementation plan

Goal: compare the existing approved product prototype against native Swift, and complete the locally implementable gaps.
Architecture: extend the current local repositories and SwiftUI routes; isolated adapters own HealthKit/EventKit/CoreLocation; existing recording, transfer, ASR, model configuration and bundle IDs remain compatible.
Stack: SwiftUI, Foundation, SQLite, sqliteai/sqlite-vector, NaturalLanguage, HealthKit, EventKit, CoreLocation, existing FoundationModels/WhisperKit. iOS 26+, watchOS 10+.
Baseline: 773b6acba5e36d9aaee17eb5e26bbfb5a7fa6db8, current feature branch codex/pages-api-base. Native paths are clean at start; unrelated repository and website edits are preserved. Internal commits in the isolated task worktree are allowed; no main-checkout commit, push, service writes or real personal-data access during implementation.

## Task 1: local life sources
- [x] Add persistent life-source snapshots and per-source enabled settings, with atomic storage and errors.
- [x] Add read-only HealthKit daily steps and sleep, EventKit calendar events, and opt-in foreground one-shot location for newly saved records.
- [x] Never request authorization at launch. Enabling requests only its source permission. Disable stops new queries/capture and keeps prior snapshots. Distinguish empty/denied/unavailable/error; HealthKit does not reveal read authorization, so no false permission claim.
- [x] Merge overlapping sleep intervals and avoid sample double counting. Date intervals use Calendar and handle DST. Stable record IDs prevent duplicate imports. Calendar cancellation removes stale current-day cached entries on successful refresh. Source error preserves prior data and labels it stale.
- [x] Source sheet supports enable, pause, refresh, status/error and system-settings route. No calendar/Health writes or continuous/background location collection.
- [x] Integrate metrics (step/sleep if readable, otherwise thought/photo independently), life filter, detail, source labels, rhythm and AI permission switches.
- [x] Test aggregation, persistence, pause/restart, empty/stale/error and deletion suppression. Build iOS.

## Task 2: assistant conversation continuity
- [x] Retain bounded conversation turns and references across tabs/relaunch; locally persisted, explicit clear action.
- [x] Follow-up uses bounded preceding context with current allowed evidence; source deletion/content change/permission revocation invalidates affected turns and in-flight results.
- [x] Remote confirmation includes all text that will be sent; settings changes invalidate pending sends. Do not auto-send or read credentials before confirmation.
- [x] Render multiple turns, retry and cancel consistently. Test persistence, source revocation, cancellation races and follow-up grounding.

## Task 3: daily insight and parity
- [x] Generate a dated insight and small proposed next action from multiple allowed records through the existing local model and citations; unavailable model has an honest fallback, no fabricated inference.
- [x] Cache only current evidence; explicit generate/refresh/retry/cancel; local automatic foreground refresh respects proactive/quiet settings and daily limit. Never silently call a custom remote model.
- [x] Insight action creates only a reminder draft; user confirms time/title.
- [x] Persist 'not relevant' feedback for the exact source revision.
- [x] Align visible WiseLife branding, preserving storage keys, bundle identifiers and Watch transfer protocol.
- [x] Run existing local suite, unsigned simulator/device builds, source-membership check; record untested real-device paths.

## Global Constraints
- Keep audio/image files, stable record UUIDs, current Watch transfer and ASR behavior. Preserve bundle IDs, target names, signing teams and minimum OS versions.
- Local-first. No embedding or record content sent to a service; no silent model downloads. Remote answer generation retains existing exact-content confirmation.
- Source permission/date scope, deletion and edits apply before any result becomes AI evidence. Keep honest keyword fallback when embeddings are unavailable.
- Preserve unrelated dirty repository/prototype changes. Internal scoped worktree commits only; no push or deployment.

## Task 4: shared local SQLite storage
- [x] Add one protected application SQLite database with versioned schema, foreign keys, prepared statements/bindings, transactions, busy timeout, WAL and useful date/source indexes. Use system SQLite; provide a small reusable access layer for the next vector task.
- [x] Use targeted updates for unbounded life history: changing one source/day or setting must not rewrite all other days. Bounded conversation/insight archives may use simple transactional replacement.
- [x] Move life-source settings/snapshots/records/suppression, dated conversations/turns, and insight entries/daily budgets into proper per-row tables. Bounded nested evidence/source structures may be JSON per row; never use one full archive blob as a database.
- [x] Atomically and idempotently migrate existing life/conversation JSON and insight UserDefaults archives. Preserve originals, IDs, date semantics, stale flags, mappings, suppression, dismissal, failed/cancelled attempt rows and budgets. Import failure must not mark complete or silently overwrite corrupt source.
- [x] Publish memory changes only after durable commit, surface storage/load errors in the existing UI, and prevent automatic model generation if attempt reservation fails. Reserve attempt + daily budget in one transaction. Reopen/reset domain behavior stays explicit and isolated.
- [x] Keep notes/photo media repositories stable; next task indexes searchable projections by existing UUID. Add project/generator membership without regenerating unrelated signing settings.
- [x] Meaningful tests: roundtrip/reopen, migration once, corrupt source rollback/preservation, transaction rollback/constraint failure, cross-domain isolation, insight attempt atomicity and errors. Run full local suite and simulator build.

## Task 5: local hybrid retrieval with SQLite Vector
- [x] Statically embed pinned official sqliteai/sqlite-vector 1.1.2 C sources under Apache-2.0, using SQLITE_CORE with system SQLite and explicit sqlite3_vector_init. Include license/provenance; no arbitrary extension loading or second SQLite engine.
- [x] Store record projections, bounded text chunks and Float32 vectors in SQLite, versioned by embedding model/revision/dimension/language and content fingerprint. Reconcile edited/deleted records, prune inaccessible vectors and rebuild incompatible model indexes.
- [x] Use real local NaturalLanguage embeddings when assets/language are available; provide resource status and explicit Apple asset download control where supported. No hashes/random vectors posing as embeddings. Use bounded work off the UI thread and skip unchanged content.
- [x] Integrate semantic ranking with keyword/date retrieval in actual search and Ask AI. Enforce date/source permissions before final ranking; never global-top-k then postfilter. Preserve cited source identity, budgets and remote confirmation. Daily summary still uses broad daily coverage.
- [x] Missing assets/unsupported language/index failures fall back to keyword search with honest status. Date, permission, source revision and cancellation races cannot leak stale results. Restrict retrieval to the selected/requested day as the current product contract.
- [x] Test actual compiled extension queries, filter-before-limit, model-version invalidation, edit/delete reconciliation and fallback using synthetic data/injected embeddings. Build device+simulator; do not claim on-device semantic quality without physical acceptance.

## Task 6: current hardware navigation parity
- [x] Main checkout prototype advanced to commit 8be638c during implementation, adding a hardware selector. Mirror the selector from its daybook-hardware.js in native navigation and settings while retaining the current Watch status view and real WCSession status.
- [x] Show Apple Watch with actual reachable/paired/installed state; refresh existing status. Keep pairing under Apple's Watch app and do not offer fabricated in-app disconnect/pairing or unknown battery/sync values.
- [x] Show EurekaRing as planned/not integrated, with honest explanation that SDK/device protocol is needed. Do not simulate a successful native connection. Hardware records remain local and existing Watch protocol stays unchanged.
- [x] Use existing visual style/localization and preserve settings/source routes. Fix remaining visible legacy app installation name and LifeSourceViews iOS26 Text concatenation deprecation while touching UI parity. Verify project membership and simulator build; no new UI access attempt after automatic approval denial.

## Outside executable scope
- EurekaRing: official hardware is pre-launch and SDK/transport contract not provided; do not invent a working integration.
- User-owned cloud storage: provider/protocol and conflict/backup contract not specified. Keep coming-soon, do not add an arbitrary upload destination.
- iOS cannot guarantee continuous background AI or all-day recording; current-day refresh is foreground and confirmed reminders use system local notifications.
- Cross-day semantic memory and a new image-description model remain outside the current dated product flow. SQLite and SQLite Vector are now explicitly required by the user.

## Progress
- Audit: recording, transfer, local ASR/resources, custom AI, photo OCR, reminder persistence already implemented.
- Implementation, final review and local integration complete. Physical-device authorization, UI and model quality remain acceptance items on the user's devices.
