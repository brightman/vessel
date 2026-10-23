import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from scripts.dev import notes_e2e_helpers


def test_tool_name_for_suffix_reads_adk_function_declarations() -> None:
    tools = [
        {
            "function_declarations": [
                {"name": "mcp_runtime_notes_read_current_page"},
                {"name": "mcp_runtime_notes_begin_note_edit"},
            ]
        }
    ]

    assert notes_e2e_helpers.tool_name_for_suffix(tools, "read_current_page") == "mcp_runtime_notes_read_current_page"


def test_notes_deferred_search_selects_the_allowed_tool_names() -> None:
    tools = [{"function_declarations": [{"name": "tool_search"}]}]

    assert notes_e2e_helpers.notes_deferred_search_call(
        tools,
        ["read_current_page", "begin_note_edit"],
    ) == (
        "tool_search",
        {"query": "select:mcp_runtime_notes_read_current_page,mcp_runtime_notes_begin_note_edit"},
    )


def test_notes_deferred_invoke_wraps_tool_name_and_arguments() -> None:
    tools = [{"function_declarations": [{"name": "invoke_deferred_tool"}]}]

    assert notes_e2e_helpers.notes_deferred_invoke_call(
        tools,
        "read_current_page",
        {"include_content": True},
    ) == (
        "invoke_deferred_tool",
        {"tool_name": "mcp_runtime_notes_read_current_page", "arguments": {"include_content": True}},
    )


def test_find_value_prefers_latest_tool_response_over_earlier_schema() -> None:
    messages = [
        {"parts": [{"function_response": {"response": {"result": '{"proposal_id":{"type":"string"}}'}}}]},
        {"parts": [{"function_response": {"response": {"result": '{"proposal_id":"proposal-live"}'}}}]},
    ]

    assert notes_e2e_helpers.find_value(messages, "proposal_id") == "proposal-live"
