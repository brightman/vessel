# Note Agent Unified UI Implementation Plan

> **For agentic workers:** use subagent-driven-development for independent backend/frontend units, with parent integration and E2E verification.

**Goal:** Unified Agent intent, interactive answers/clarification, inline document proposal previews with floating acceptance.
**Architecture:** Keep explicit ask/edit compatible; add auto mode. Persist validated structured response on Run. Auto asks Agent for a versioned JSON response with schema_version=1 and type=answer|clarification|edit, message, optional sources [{title,url}], clarification options [{id,label}] or edit proposal {base_revision,operations,summary}. Validate server side and reuse ProposalService. UI renders typed cards and preview document separately from saved draft.
**Tech Stack:** Python/FastAPI/SQLAlchemy, React/Tiptap, pytest, Playwright.

## Global constraints

Preserve unrelated dirty files. No direct DB/object-store operations on user data. No Note write before Accept. Keep existing explicit modes. Read-only Agent responses cannot create edits. Live Agent integration and deterministic E2E reported separately.

## Task 1: Backend structured response and continuation

Files: agent_platform.py, new notes/agent_response.py, models/note_agent_run.py, additive migration, tests/test_note_agent_auto.py.
- [x] Write failing API/parser tests: auto answer creates no proposal; auto edit creates valid preview; clarification returns options; invalid response/unsafe URL fails; viewer edit blocked; existing explicit modes remain compatible.
- [x] Run pytest on new tests and confirm feature failures.
- [x] Add auto mode default, strict JSON response parser, persistent response_json + message + continuation reference with migration. get Run exposes response and prompt; status exposes latest completed Run for reload. Frontend fields: response {schema_version:1,type,message,sources?,options?}, prompt. edit response may contain proposal but UI must render server proposal.
- [x] Continuation fields on start: reply_to_run_id?, option_id?; server checks owner/Note and completed clarification, bounds selected ID and prevents repeat response; free text allowed. Include original task and answer in new Run context. Do not change configured external Agent: auto use_output_schema=false with strict instructed JSON output; explicit edit retains current schema.
- [x] Run focused API tests.

## Task 2: Frontend cards and inline preview

Files: NoteAgent.tsx, Notes.tsx, api.ts, new note-agent cards/styles as useful, tests/e2e/note-agent-ui.spec.mjs.
- [x] Write failing browser test with controlled API responses for no toggles, answer/clarification, inline preview, Accept persisted after reload, Reject restores original.
- [x] Add AgentMode auto types and AgentResponse contract matching task 1; expose get Run prompt/response and latest_run on status.
- [x] Render one composer and typed cards; clarification sends reply_to_run_id and option_id or free text. Show real elapsed status and restore latest response after reload.
- [x] Add onPreview callback from NoteAgent to Notes. Render preview title/document with NoteEditor readOnly and a preview banner, prevent draft mutation. Float Accept/Reject/View changes on main paper using a portal or coordinated controls. Dirty drafts prevent proposal overlay until saved. On Reject or Accept remove preview; selecting Note resets preview. Refresh active proposals during Run to show complete validated changes only. Lock manual document edits while preview shown. Allow further prompts based on existing proposal preview only if backend continuation is explicit; otherwise safely regenerate against current saved Note.
- [x] Add highlights for changed/new blocks and optional before/after comparison including deleted content.
- [x] Build web and run Playwright controlled tests.

## Task 3: Integration and real verification

- [x] Review branch diffs and API consistency, migration upgrade and SQL dialect path.
- [x] Run focused backend suites and frontend build; resolve regressions in touched scope.
- [x] Run integrated E2E against isolated test service where available and real configured Agent; browser inspect final layout using cua_repl.
- [x] Document exact passing tests, artifacts, any live configuration/runtime limitations; leave changes reviewable without committing unrelated files.

## Completion notes

Implemented and verified in the existing dirty development checkout to preserve current uncommitted Note runtime work. Changes remain uncommitted. Full evidence and limits: docs/note-agent-unified-ui-verification.md. Preview mounts after whole validated proposal, not partial JSON tokens. Auto uses strict instructed response contract with bounded envelope extraction; explicit legacy ask/edit remain compatible.
