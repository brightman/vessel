# Note Agent rich-text verification

Date: 2026-10-17. Local Vessel at 127.0.0.1:52003 and Baizhi at 127.0.0.1:8787, using the configured real model and run-scoped MCP. User authorized browser operations on the current test Note.

## Results

Note: `daf884e4-f978-4216-80c8-95d39e885961` (`Note MCP Edit 验收 2026-10-17`). Existing title and two paragraphs retained. Agent appended four real document blocks: heading, paragraph with a bold mark, image, and table.

- Text: `这段文本由 Note Agent 插入。`; DOM confirmed a strong element containing `Note Agent`.
- Image: local synthetic SVG test fixture, alt `Note Agent 富文本测试图片`; DOM confirmed complete=true, naturalWidth=640, naturalHeight=240 after reload. This tests insertion by image URL, not image generation or private attachment upload. Fixture copy: `var/note-mcp-screens/note-agent-test.svg`; served copy: `dist/marketing/assets/note-agent-test.svg` (a rebuild may remove it).
- Table: actual table/tableRow/tableHeader/tableCell nodes, with paragraph/text children; DOM confirmed 4 rows and 3 columns and every expected cell value after reload.
- Approval: current Note remained unchanged before acceptance. Accepted proposal `bb3d5d1f-4a20-4342-98ac-36e72db289ba`, then reloaded and verified all inserted blocks.
- Editor normalization caused an additional unsaved state after acceptance/loading; explicitly saved the normalized document once. Subsequent reload showed Saved, no further unsaved state. This normalization behavior was observed, not changed in this task.

Screenshot: `var/note-mcp-screens/richtext-after-reload.png`.

## Bug fixed

`render_table_cell` previously rendered only direct inline children, so editor-standard cells containing paragraph blocks exported as empty strings. The first real proposal reproduced the empty Markdown table and was rejected without modifying the Note. Added a failing regression covering paragraph cells, bold marks, pipe escaping, and multiline content; fixed rendering while retaining compatibility with existing direct-inline cells. Repeated the Agent Edit flow after reloading the API; the new preview retained all cell text.

Verification command:

```sh
apps/api/.venv/bin/python -m pytest apps/api/tests/test_document_codec.py apps/api/tests/test_notes_mcp.py apps/api/tests/test_note_agent_runtime_mcp.py apps/api/tests/test_proposal_service.py -q --tb=short
```

Result: 18 passed. No remote deployment, image-generation, private-upload, or load-test acceptance is claimed.
