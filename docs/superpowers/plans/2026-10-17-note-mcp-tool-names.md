# Note MCP tool names implementation plan

Goal: Fix model-facing Note MCP names exceeding 64 characters and verify the complete Edit path.

Architecture: Use the stable run-local MCP ID `vessel_note`. Keep authorization in the existing expiring Note/Run capability, never in the tool name. Baizhi's MCP session key includes headers, so different Run credentials retain separate sessions. No persistent MCP binding is added.

- [x] Add regressions against the current non-legacy Run adapter: all five prefixed tool names fit 64 characters, distinct Runs receive distinct scoped tokens, and tokens bind the expected Note and Run.
- [x] Observe failure (84-character read tool), replace the generated MCP ID with the short stable ID, rerun focused tests (5 passed).
- [x] Reload the local API. In the authorized signed-in browser, create a dedicated test Note, request an Edit proposal, verify the Note is unchanged before acceptance, accept and reload to verify persistence.
- [x] Record test results and remaining boundaries. Preserve existing unrelated changes.

## Verification

Command: `apps/api/.venv/bin/python -m pytest apps/api/tests/test_note_agent_runtime_mcp.py apps/api/tests/test_notes_mcp.py -q --tb=short` (5 passed).

Local E2E: Vessel `127.0.0.1:52003` -> Baizhi `127.0.0.1:8787` -> real configured model -> run-scoped Note MCP -> ready proposal -> user acceptance -> revision 3 -> browser reload. Agent logs confirmed discovery of all five tools and successful calls. Note `daf884e4-f978-4216-80c8-95d39e885961`, Run `run_notes_95e29efcf3b0438aa10e202d62764aa7`, proposal `0a56a466-9a33-41ec-9a2a-2b906b59f4e2`.

Test Note: `Note MCP Edit 验收 2026-10-17`. Original paragraph retained; appended `Note MCP Edit 链路验收通过。`. Before acceptance, only the proposal preview contained the new paragraph. After acceptance and reload, the saved document contained both paragraphs. Screenshots: `var/note-mcp-screens/before-accept.png`, `var/note-mcp-screens/after-accept-reload.png`.

Boundary: local integration verified, no remote deployment performed. Existing legacy `test_agent_platform.py` still imports removed `_ensure_agent_thread` and cannot collect; `test_note_capabilities.py` has an existing error-message mismatch (`Note not found` vs `Note access denied`). Neither was changed or counted as passing. Personal MCP inheritance remains unchanged.
