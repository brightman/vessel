from copy import deepcopy
import re
from typing import Any
from urllib.parse import urlparse
from uuid import uuid4


BLOCK_TYPES = {
    "paragraph",
    "heading",
    "bulletList",
    "orderedList",
    "listItem",
    "taskList",
    "taskItem",
    "blockquote",
    "codeBlock",
    "horizontalRule",
    "table",
    "tableRow",
    "tableHeader",
    "tableCell",
    "image",
    "notesImage",
}
INLINE_TYPES = {"text", "hardBreak"}
ALLOWED_TYPES = BLOCK_TYPES | INLINE_TYPES | {"doc"}
ALLOWED_MARKS = {"bold", "italic", "underline", "strike", "code", "link"}
PRIVATE_ASSET_URL = re.compile(
    r"^/v1/assets/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/content$"
)


def _is_safe_image_url(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    return urlparse(value).scheme in {"http", "https"} or bool(PRIVATE_ASSET_URL.fullmatch(value))


class DocumentValidationError(ValueError):
    pass


def normalize_document(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or value.get("type") != "doc":
        raise DocumentValidationError("Document root must be a doc node")
    if value.get("schema_version") != 1:
        raise DocumentValidationError("Unsupported document schema version")
    content = value.get("content", [])
    if not isinstance(content, list):
        raise DocumentValidationError("Document content must be a list")

    normalized = deepcopy(value)
    block_ids: set[str] = set()

    def visit(node: Any, top_level: bool = False) -> None:
        if not isinstance(node, dict) or node.get("type") not in ALLOWED_TYPES - {"doc"}:
            raise DocumentValidationError("Document contains an unsupported node")
        node_type = node["type"]
        if node_type == "notesImage":
            node["type"] = "image"
            node_type = "image"
        if node_type == "text" and not isinstance(node.get("text"), str):
            raise DocumentValidationError("Text nodes require string content")
        attrs = node.get("attrs")
        if attrs is not None and not isinstance(attrs, dict):
            raise DocumentValidationError("Node attributes must be an object")
        if isinstance(attrs, dict) and "block-id" in attrs:
            attrs["block_id"] = attrs.pop("block-id")
        if top_level:
            block_id = (attrs or {}).get("block_id")
            if not isinstance(block_id, str) or not block_id.strip():
                raise DocumentValidationError("Top-level blocks require a stable block_id")
            if block_id in block_ids:
                raise DocumentValidationError("Block IDs must be unique")
            block_ids.add(block_id)
        for mark in node.get("marks", []):
            if not isinstance(mark, dict) or mark.get("type") not in ALLOWED_MARKS:
                raise DocumentValidationError("Document contains an unsupported mark")
            if mark["type"] == "link":
                href = (mark.get("attrs") or {}).get("href", "")
                if urlparse(href).scheme not in {"http", "https", "mailto"}:
                    raise DocumentValidationError("Links must use HTTP, HTTPS, or mailto")
        children = node.get("content", [])
        if not isinstance(children, list):
            raise DocumentValidationError("Node content must be a list")
        for child in children:
            visit(child)

    for child in normalized.get("content", []):
        visit(child, top_level=True)
    return normalized


def markdown_from_document(document: dict[str, Any]) -> str:
    normalized = normalize_document(document)
    rendered = [render_block(node) for node in normalized.get("content", [])]
    return "\n\n".join(item for item in rendered if item).rstrip() + ("\n" if any(rendered) else "")


def render_block(node: dict[str, Any]) -> str:
    node_type = node["type"]
    children = node.get("content", [])
    if node_type == "paragraph":
        return render_inline(children)
    if node_type == "heading":
        level = int((node.get("attrs") or {}).get("level", 1))
        if level not in (1, 2, 3, 4, 5, 6):
            raise DocumentValidationError("Heading level must be between 1 and 6")
        return f"{'#' * level} {render_inline(children)}".rstrip()
    if node_type in {"bulletList", "orderedList", "taskList"}:
        return render_list(node)
    if node_type == "blockquote":
        lines = "\n".join(render_block(child) for child in children).splitlines()
        return "\n".join(f"> {line}" if line else ">" for line in lines)
    if node_type == "codeBlock":
        language = (node.get("attrs") or {}).get("language", "")
        code = "".join(child.get("text", "") for child in children)
        fence = "```"
        while fence in code:
            fence += "`"
        return f"{fence}{language}\n{code}\n{fence}"
    if node_type == "horizontalRule":
        return "---"
    if node_type == "image":
        attrs = node.get("attrs") or {}
        src = attrs.get("src")
        if src and not _is_safe_image_url(src):
            raise DocumentValidationError("Image URLs must use HTTP or HTTPS")
        alt = attrs.get("alt", "")
        caption = render_inline(children)
        image = f"![{alt}]({src})" if src else ""
        return f"{image}\n\n{caption}".strip()
    if node_type == "table":
        rows = [[render_table_cell(cell) for cell in row.get("content", [])] for row in children]
        if not rows:
            return ""
        width = max((len(row) for row in rows), default=0)
        rows = [row + [""] * (width - len(row)) for row in rows]
        output = ["| " + " | ".join(rows[0]) + " |", "| " + " | ".join(["---"] * width) + " |"]
        output.extend("| " + " | ".join(row) + " |" for row in rows[1:])
        return "\n".join(output)
    if node_type in INLINE_TYPES:
        return render_inline([node])
    if node_type in {"listItem", "taskItem", "tableRow", "tableCell", "tableHeader", "doc"}:
        return "\n".join(render_block(child) for child in children)
    raise DocumentValidationError("Document contains an unsupported block")


def render_list(node: dict[str, Any], depth: int = 0) -> str:
    node_type = node["type"]
    start = int((node.get("attrs") or {}).get("start", 1))
    lines = []
    for index, item in enumerate(node.get("content", [])):
        if node_type == "orderedList":
            marker = f"{start + index}. "
        elif node_type == "taskList":
            checked = (item.get("attrs") or {}).get("checked") is True
            marker = f"- [{'x' if checked else ' '}] "
        else:
            marker = "- "
        item_content = item.get("content", [])
        text = " ".join(render_block(child) for child in item_content if child.get("type") not in {"bulletList", "orderedList", "taskList"})
        lines.append("  " * depth + marker + text)
        for child in item_content:
            if child.get("type") in {"bulletList", "orderedList", "taskList"}:
                lines.append(render_list(child, depth + 1))
    return "\n".join(lines)


def render_table_cell(cell: dict[str, Any]) -> str:
    children = cell.get("content", [])
    # Editor and MCP cells contain paragraph blocks; Markdown imports may
    # still contain direct inline nodes. Preserve both representations.
    if any(child.get("type") not in INLINE_TYPES for child in children):
        rendered = "\n".join(render_block(child) for child in children)
    else:
        rendered = render_inline(children)
    return rendered.replace("|", "\\|").replace("\n", "<br>")


def render_inline(nodes: list[dict[str, Any]]) -> str:
    result = []
    for node in nodes:
        if node.get("type") == "hardBreak":
            result.append("  \n")
            continue
        value = node.get("text", "")
        for mark in node.get("marks", []):
            mark_type = mark["type"]
            if mark_type == "bold":
                value = f"**{value}**"
            elif mark_type == "italic":
                value = f"*{value}*"
            elif mark_type == "strike":
                value = f"~~{value}~~"
            elif mark_type == "code":
                value = f"`{value}`"
            elif mark_type == "underline":
                value = f"<u>{value}</u>"
            elif mark_type == "link":
                href = (mark.get("attrs") or {}).get("href", "")
                value = f"[{value}]({href})"
        result.append(value)
    return "".join(result)


def markdown_to_document(markdown: str) -> dict[str, Any]:
    """Parse the Notes Markdown subset into the canonical ProseMirror document tree."""
    if not isinstance(markdown, str):
        raise DocumentValidationError("Markdown content must be text")
    if len(markdown) > 2_000_000:
        raise DocumentValidationError("Markdown content exceeds the 2 MB limit")
    lines = markdown.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    blocks, _ = _parse_markdown_blocks(lines, 0)
    return normalize_document({"type": "doc", "schema_version": 1, "content": blocks})


def _parse_inline(text: str, marks: list[dict[str, Any]] | None = None) -> list[dict[str, Any]]:
    active_marks = marks or []
    result: list[dict[str, Any]] = []
    index = 0

    def append_text(value: str, inherited: list[dict[str, Any]]) -> None:
        if value:
            result.append({"type": "text", "text": value, **({"marks": inherited} if inherited else {})})

    while index < len(text):
        if text[index] == "\\" and index + 1 < len(text):
            append_text(text[index + 1], active_marks)
            index += 2
            continue
        if text[index] == "[":
            close = text.find("](", index + 1)
            end = text.find(")", close + 2) if close >= 0 else -1
            if close >= 0 and end >= 0:
                label = text[index + 1 : close]
                href = text[close + 2 : end].split(maxsplit=1)[0]
                link_marks = [*active_marks, {"type": "link", "attrs": {"href": href}}]
                result.extend(_parse_inline(label, link_marks))
                index = end + 1
                continue
        delimiter_map = (("**", "bold"), ("__", "bold"), ("~~", "strike"), ("`", "code"), ("*", "italic"), ("_", "italic"))
        matched = False
        for delimiter, mark_name in delimiter_map:
            if not text.startswith(delimiter, index):
                continue
            end = text.find(delimiter, index + len(delimiter))
            if end <= index + len(delimiter):
                continue
            content = text[index + len(delimiter) : end]
            if mark_name == "code":
                append_text(content, [*active_marks, {"type": mark_name}])
            else:
                result.extend(_parse_inline(content, [*active_marks, {"type": mark_name}]))
            index = end + len(delimiter)
            matched = True
            break
        if matched:
            continue
        if text[index] == "\n":
            append_text(" ", active_marks)
            index += 1
            continue
        next_positions = [position for position in (
            text.find("[", index), text.find("**", index), text.find("__", index),
            text.find("~~", index), text.find("`", index), text.find("*", index),
            text.find("_", index), text.find("\\", index), text.find("\n", index),
        ) if position >= 0]
        next_index = min(next_positions) if next_positions else len(text)
        if next_index == index:
            append_text(text[index], active_marks)
            index += 1
        else:
            append_text(text[index:next_index], active_marks)
            index = next_index
    return result


def _block_id(node: dict[str, Any]) -> dict[str, Any]:
    attrs = dict(node.get("attrs") or {})
    attrs["block_id"] = str(uuid4())
    node["attrs"] = attrs
    return node


def _paragraph(text: str) -> dict[str, Any]:
    return {"type": "paragraph", "content": _parse_inline(text)}


def _list_marker(line: str) -> tuple[int, str, str] | None:
    match = re.match(r"^( *)([-+*]|\d+[.)])\s+(.*)$", line)
    if not match:
        return None
    return len(match.group(1)), match.group(2), match.group(3)


def _parse_list(lines: list[str], start: int) -> tuple[dict[str, Any], int]:
    first = _list_marker(lines[start])
    assert first is not None
    indent, marker, item_text = first
    initial_task = re.match(r"^\[([ xX])\]\s*(.*)$", item_text)
    kind = "taskList" if initial_task else "orderedList" if marker[0].isdigit() else "bulletList"
    items: list[dict[str, Any]] = []
    index = start
    while index < len(lines):
        current = _list_marker(lines[index])
        if not current or current[0] != indent:
            break
        current_indent, current_marker, content = current
        task = re.match(r"^\[([ xX])\]\s*(.*)$", content)
        current_kind = "taskList" if task else "orderedList" if current_marker[0].isdigit() else "bulletList"
        if current_kind != kind:
            break
        if task:
            checked = task.group(1).lower() == "x"
            content = task.group(2)
            item: dict[str, Any] = {
                "type": "taskItem", "attrs": {"checked": checked},
                "content": [_paragraph(content)],
            }
        else:
            item = {"type": "listItem", "content": [_paragraph(content)]}
        index += 1
        nested: list[dict[str, Any]] = []
        while index < len(lines):
            nested_marker = _list_marker(lines[index])
            if nested_marker and nested_marker[0] > current_indent:
                child, index = _parse_list(lines, index)
                nested.append(child)
                continue
            if lines[index].startswith("  ") and lines[index].strip() and not nested_marker:
                item["content"][0]["content"].extend(_parse_inline(lines[index].strip()))
                index += 1
                continue
            break
        item["content"].extend(nested)
        items.append(item)
    attrs: dict[str, Any] = {}
    if kind == "orderedList":
        attrs["start"] = int(marker[:-1]) if marker.endswith((".", ")")) else 1
    return {"type": kind, "attrs": attrs, "content": items}, index


def _is_table_separator(line: str) -> bool:
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    return bool(cells) and all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells)


def _table_row(line: str, header: bool = False) -> dict[str, Any]:
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    kind = "tableHeader" if header else "tableCell"
    return {
        "type": "tableRow",
        "content": [{"type": kind, "content": _parse_inline(cell)} for cell in cells],
    }


def _is_block_start(lines: list[str], index: int) -> bool:
    line = lines[index]
    if not line.strip():
        return True
    if re.match(r"^#{1,6}\s+", line) or re.match(r"^(```+|~~~+)", line):
        return True
    if re.match(r"^\s*> ?", line) or _list_marker(line):
        return True
    if re.fullmatch(r"\s*(?:-{3,}|\*{3,}|_{3,})\s*", line):
        return True
    if line.lstrip().startswith("!["):
        return True
    return index + 1 < len(lines) and line.lstrip().startswith("|") and _is_table_separator(lines[index + 1])


def _parse_markdown_blocks(lines: list[str], start: int) -> tuple[list[dict[str, Any]], int]:
    blocks: list[dict[str, Any]] = []
    index = start
    while index < len(lines):
        line = lines[index]
        if not line.strip():
            index += 1
            continue
        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        if heading:
            blocks.append(_block_id({
                "type": "heading", "attrs": {"level": len(heading.group(1))},
                "content": _parse_inline(heading.group(2).strip()),
            }))
            index += 1
            continue
        fence = re.match(r"^\s*(`{3,}|~{3,})(.*)$", line)
        if fence:
            delimiter = fence.group(1)
            language = fence.group(2).strip().split(maxsplit=1)[0] if fence.group(2).strip() else ""
            index += 1
            code_lines = []
            while index < len(lines) and not re.match(rf"^\s*{re.escape(delimiter[0])}{{{len(delimiter)},}}\s*$", lines[index]):
                code_lines.append(lines[index])
                index += 1
            if index < len(lines):
                index += 1
            blocks.append(_block_id({"type": "codeBlock", "attrs": {"language": language}, "content": ([{"type": "text", "text": "\n".join(code_lines)}] if code_lines else [])}))
            continue
        if re.fullmatch(r"\s*(?:-{3,}|\*{3,}|_{3,})\s*", line):
            blocks.append(_block_id({"type": "horizontalRule"}))
            index += 1
            continue
        if re.match(r"^\s*> ?", line):
            quoted = []
            while index < len(lines) and re.match(r"^\s*> ?", lines[index]):
                quoted.append(re.sub(r"^\s*> ?", "", lines[index]))
                index += 1
            children, _ = _parse_markdown_blocks(quoted, 0)
            blocks.append(_block_id({"type": "blockquote", "content": children or [_paragraph("")]}))
            continue
        if line.lstrip().startswith("!["):
            image = re.fullmatch(r"\s*!\[([^\]]*)\]\((.+)\)\s*", line)
            if image:
                if not _is_safe_image_url(image.group(2)):
                    raise DocumentValidationError("Image URLs must use HTTP or HTTPS")
                blocks.append(_block_id({"type": "image", "attrs": {"alt": image.group(1), "src": image.group(2)}}))
                index += 1
                continue
        if index + 1 < len(lines) and line.lstrip().startswith("|") and _is_table_separator(lines[index + 1]):
            header = _table_row(line, header=True)
            index += 2
            rows = [header]
            while index < len(lines) and lines[index].lstrip().startswith("|"):
                rows.append(_table_row(lines[index]))
                index += 1
            blocks.append(_block_id({"type": "table", "content": rows}))
            continue
        if _list_marker(line):
            list_node, index = _parse_list(lines, index)
            blocks.append(_block_id(list_node))
            continue
        paragraph_lines = [line.strip()]
        index += 1
        while index < len(lines) and not _is_block_start(lines, index):
            paragraph_lines.append(lines[index].strip())
            index += 1
        blocks.append(_block_id(_paragraph(" ".join(paragraph_lines))))
    return blocks, index
