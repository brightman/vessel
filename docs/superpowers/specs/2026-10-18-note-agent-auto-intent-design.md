# Note Agent unified input

Remove Ask/Edit controls from the Note sidebar. Users send questions and edit requests through one composer. The Agent decides whether to answer or propose changes based on user intent and the saved Note context; the frontend does not classify keywords.

## Recommended design

Add an automatic intent mode to the existing run contract, preserving explicit ask/edit API callers. In automatic mode the Agent returns a structured answer or an edit proposal. The server validates the selected response type and operations; an answer must not create a proposal. A proposal must respect the saved base revision and write permission. Read-only users can ask questions, but cannot create or accept edits. Keep existing explicit modes compatible with their existing output schema.

The unified composer says “Ask a question or describe changes…” and explains that proposed changes need approval. Conversation labels do not claim an edit before the Agent has chosen one. Preserve run reconnect, cancellation, unsaved-note handling and error display.

## Alternatives

1. Recommended: one structured Agent response discriminates answer from edit; one run and no separate classifier invocation. Requires updating the configured Agent output schema in coordination with server support.
2. A classifier run followed by existing Ask/Edit run preserves existing output shapes but adds latency and failure states.
3. Client keyword rules are simple but cannot satisfy the requirement that the Agent decides intent.

## Acceptance and verification

- Sidebar has one composer and no Ask/Edit toggle.
- An ordinary question returns a readable answer without creating a proposal or changing the Note.
- An edit request creates a reviewable proposal; accepting it updates the Note and survives reload.
- Rejection leaves the Note unchanged; stale revision and read-only permissions are enforced by the server.
- Existing explicit Ask/Edit callers remain compatible.
- Cover response parsing, permission enforcement and run handling with focused tests, then run browser E2E for both question and edit flows.
- Verify real configured Agent responses in the local browser in addition to deterministic E2E coverage. Report any configuration or runtime blocker honestly.

## Scope

Only unify Note Agent intent selection and the associated response contract. Do not change unrelated dirty repository files. Do not claim the previously stalled tennis task is fixed without a separate successful live run.
