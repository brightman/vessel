"""Safe progress events for the Note Agent sidebar."""

from vessel_service import agent_platform


def test_tool_progress_exposes_only_allowlisted_name_and_phase():
    started = agent_platform._progress_event("TOOL_CALL_START", {
        "toolCallName": "web_search", "toolCallId": "private-id", "arguments": "private query",
    })
    completed = agent_platform._progress_event("TOOL_CALL_RESULT", {
        "toolCallName": "web_search", "content": "private search results",
    })
    assert started == {"phase": "tool_started", "tool": "web_search"}
    assert completed == {"phase": "tool_completed", "tool": "web_search"}


def test_reasoning_and_answer_content_are_not_progress_events():
    assert agent_platform._progress_event("REASONING_START", {"text": "private thought"}) == {"phase": "thinking"}
    assert agent_platform._progress_event("REASONING_MESSAGE_CONTENT", {"delta": "private thought"}) is None
    assert agent_platform._progress_event("TEXT_MESSAGE_CONTENT", {"delta": "private answer"}) is None
    assert agent_platform._progress_event("TOOL_CALL_START", {"toolCallName": "untrusted-private-tool"}) == {"phase": "tool_started", "tool": "tool"}


def test_sse_frame_drops_private_payload_and_preserves_terminal_status():
    progress = agent_platform._safe_progress_frame(
        "TOOL_CALL_START", ['{"payload":{"toolCallName":"web_search","arguments":"secret query","content":"private note"}}']
    )
    terminal = agent_platform._safe_progress_frame("done", ['{"status":"completed"}'])

    assert progress == 'event: progress\ndata: {"payload":{"phase":"tool_started","tool":"web_search"}}\n\n'
    assert terminal == 'event: done\ndata: {"status":"completed"}\n\n'
    assert agent_platform._safe_progress_frame("TOOL_CALL_ARGS", ['{"payload":{"delta":"secret query"}}']) is None
    assert agent_platform._safe_progress_frame("done", ['{"status":{"unexpected":"object"}}']) is None
