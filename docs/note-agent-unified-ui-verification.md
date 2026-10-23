# Note Agent unified UI verification

Date: 2026-10-18 (Asia/Singapore).

## Delivered

- One composer with Agent-selected answer / clarification / edit response.
- Markdown answers (GFM lists/tables, raw HTML suppressed), source cards and interactive clarification choices with free-text continuation.
- Run response persistence and latest response recovery after reload; server-side ownership, selected option and consumed-clarification checks.
- Saved Note remains untouched while the actual editor displays validated proposal title/body/table/image nodes in read-only form. Changed blocks highlighted, before/after comparison and floating acceptance controls.
- Accept persists via existing CAS/versioned proposal service, Reject restores saved content, refinement replaces pending proposal only after valid new edit.
- Draft, read-only, stale revision and cross-Note delayed-accept safeguards.

## Verification results

1. `PYTHONPATH=apps/api/src apps/api/.venv/bin/python -m pytest apps/api/tests/test_note_agent_auto.py apps/api/tests/test_proposal_api.py apps/api/tests/test_proposal_service.py apps/api/tests/test_document_codec.py -q`: **28 passed**.
2. `node_modules/.bin/playwright test tests/e2e/note-agent-ui.spec.mjs --reporter=line` with local Vite: **11 passed**. Covers unified composer, sources, refresh recovery, clarification, inline preview, reject/accept, stale revision, viewer, failed acceptance, draft preservation, answered choices, same-note preview lifecycle, delayed Accept/navigation and Markdown/HTML handling.
3. Isolated PostgreSQL, real Vessel HTTP API, controlled HTTP Agent gateway via `scripts/dev/note_agent_ui_e2e.py`: **2 passed**. Browser drives registration, Note creation/save, answer, table edit preview, rejection, acceptance/reload, clarification/reload/continuation. Fresh database migration through 0014 succeeded.
4. Same isolated service using the actual configured Agent gateway via `scripts/dev/note_agent_ui_e2e.py --live`: **2 passed (24.0s)**. Real Agent selected answer, edit and clarification; table proposal rendered, rejection restored original, acceptance survived reload, clarification selection continued original task.
5. `npm run build:web`: passed. Existing bundler directive/chunk warnings remain.
6. Independent code review: delayed Accept/navigation overwrite, same-note preview disappearance, Markdown rendering and continuation persistence findings fixed; scoped re-review returned no additional actionable findings.
7. Local development API migration 0014 applied; API restarted with existing database/Agent configuration. `/healthz` returned `{"status":"ok"}`. Chrome showed existing account/Notes and unified composer with Agent online.

## Runtime observations and limits

The live Agent sometimes prepended prose to otherwise valid JSON, or confused edit operation fields. Auto context now contains canonical operation examples and case-sensitive Tiptap table names. The bounded parser can discard a prose prefix or one whole JSON code fence, but only accepts a single complete envelope and still strictly validates response/proposal schema, source URLs, revision and permission. Invalid Agent output remains a visible failure rather than a write.

Preview mounts automatically after a complete proposal is validated. This is not token-by-token mutation of the document while JSON is incomplete. The prior tennis research task was not used as a factual coverage benchmark; live acceptance used small, deterministic user requests plus real Agent responses.

These are focused task suites, not a claim that the entire dirty repository passes. Historical `test_agent_platform.py` currently imports the previously removed `_ensure_agent_thread` and cannot collect; unrelated legacy tests were not rewritten in this task.

## Reproduction

Start a dedicated PostgreSQL database with `bash scripts/dev/start-e2e-postgres.sh`. Export its printed `NOTES_DATABASE_URL`, migrate using the API Alembic setup, build the console, then run:

```sh
PYTHONPATH=apps/api/src apps/api/.venv/bin/python scripts/dev/note_agent_ui_e2e.py
PYTHONPATH=apps/api/src apps/api/.venv/bin/python scripts/dev/note_agent_ui_e2e.py --live
```

`--live` loads only gateway connection settings from the local API env file into the test service; credentials never enter browser or output. Every user/Note written by these tests is in the dedicated test DB. Diagnostic output files contain only disposable test responses.

Artifacts: `var/note-agent-live-preview.png`, `var/note-agent-integrated-preview.png`.

## Follow-up: existing interrupted thread start failure

The original tennis Note reproduced a 502 `AGENT_PLATFORM_RUN_START_FAILED`. Safe diagnostics showed upstream HTTP409 `PLAN_EXECUTION_THREAD_BUSY`. Its old Run was `interrupted_max_rounds`: Vessel regarded it as terminal, while Agent Platform retained the resumable Run's thread claim. Fresh-thread live tests did not exercise this state.

Before starting a replacement request, Vessel now verifies and cancels only interrupted/awaiting-input Runs persisted for this exact Note and user, checking their upstream Run and thread identities. It does not cancel a Run that has become queued/running, or one whose thread identity differs. Remaining upstream busy conflicts are reported as `AGENT_THREAD_BUSY`, with sanitized diagnostic status/code (no response bodies or credentials logged).

Three new regression cases reproduce interrupted recovery, a resumed running Run, and wrong-thread identity. Focused API/proposal/codec suites: **31 passed**. Repeating the exact original task in the existing browser Note returned **202 Accepted** and connected SSE after the fix. Final factual research completion is separate from start-conflict recovery.
