from __future__ import annotations

import json
import re
from typing import Any


def tool_name_for_suffix(tools: Any, suffix: str) -> str | None:
    """Find a tool by name across OpenAI and ADK function-declaration shapes."""
    pending = list(tools) if isinstance(tools, list) else [tools]
    while pending:
        item = pending.pop()
        if isinstance(item, dict):
            name = item.get("name")
            if isinstance(name, str) and (name == suffix or name.endswith("_" + suffix)):
                return name
            pending.extend(item.values())
        elif isinstance(item, list):
            pending.extend(item)
    return None


def notes_deferred_search_call(tools: Any, suffixes: list[str]) -> tuple[str, dict[str, str]] | None:
    tool_name = tool_name_for_suffix(tools, "tool_search")
    if not tool_name:
        return None
    names = ",".join(f"mcp_runtime_notes_{suffix}" for suffix in suffixes)
    return tool_name, {"query": f"select:{names}"}


def find_value(value: Any, key: str) -> Any:
    """Find a result field, preferring the latest nested tool response."""
    if isinstance(value, dict):
        if key in value:
            return value[key]
        for nested in reversed(list(value.values())):
            found = find_value(nested, key)
            if found is not None:
                return found
    elif isinstance(value, list):
        for nested in reversed(value):
            found = find_value(nested, key)
            if found is not None:
                return found
    elif isinstance(value, str):
        try:
            return find_value(json.loads(value), key)
        except (json.JSONDecodeError, TypeError):
            match = re.search(rf'"{re.escape(key)}"\s*:\s*"([^"\\]+)"', value)
            if match:
                return match.group(1)
    return None


def notes_deferred_invoke_call(
    tools: Any,
    suffix: str,
    arguments: dict[str, Any],
) -> tuple[str, dict[str, Any]] | None:
    tool_name = tool_name_for_suffix(tools, "invoke_deferred_tool")
    if not tool_name:
        return None
    return tool_name, {
        "tool_name": f"mcp_runtime_notes_{suffix}",
        "arguments": arguments,
    }
