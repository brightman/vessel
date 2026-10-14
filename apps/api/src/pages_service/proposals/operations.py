"""Deterministic, atomic operations for non-authoritative Page proposals."""

from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from typing import Any

from pages_service.document.codec import DocumentValidationError, normalize_document


class OperationError(ValueError):
    """An edit operation cannot safely be applied to the current proposal."""


MAX_OPERATIONS_PER_BATCH = 100
MAX_BATCH_BYTES = 2_000_000


def _operation_fingerprint(operation: dict[str, Any]) -> str:
    canonical = json.dumps(operation, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _top_level_index(document: dict[str, Any], block_id: str) -> int:
    for index, block in enumerate(document["content"]):
        if (block.get("attrs") or {}).get("block_id") == block_id:
            return index
    raise OperationError(f"target block was not found: {block_id}")


def _find_any_block(node: dict[str, Any], block_id: str) -> dict[str, Any] | None:
    if (node.get("attrs") or {}).get("block_id") == block_id:
        return node
    for child in node.get("content", []):
        found = _find_any_block(child, block_id)
        if found is not None:
            return found
    return None


def _text_nodes(node: dict[str, Any]) -> list[dict[str, Any]]:
    found: list[dict[str, Any]] = []
    if node.get("type") == "text":
        found.append(node)
    else:
        for child in node.get("content", []):
            found.extend(_text_nodes(child))
    return found


def _replace_block(document: dict[str, Any], operation: dict[str, Any]) -> bool:
    block_id = operation.get("block_id")
    index = _top_level_index(document, block_id)
    replacement = operation.get("block")
    if not isinstance(replacement, dict):
        raise OperationError("replace_block requires a block object")
    replacement = deepcopy(replacement)
    replacement_id = (replacement.get("attrs") or {}).get("block_id")
    if replacement_id != block_id:
        raise OperationError("replacement block must preserve its stable block_id")
    changed = document["content"][index] != replacement
    document["content"][index] = replacement
    return changed


def _replace_range(document: dict[str, Any], operation: dict[str, Any]) -> bool:
    block_id = operation.get("block_id")
    index = _top_level_index(document, block_id)
    block = document["content"][index]
    expected = operation.get("expected_text")
    replacement = operation.get("replacement")
    if not isinstance(expected, str) or not expected:
        raise OperationError("replace_range requires non-empty expected_text")
    if not isinstance(replacement, str):
        raise OperationError("replace_range requires string replacement")

    leaves = _text_nodes(block)
    source = "".join(leaf.get("text", "") for leaf in leaves)
    start = source.find(expected)
    if start < 0 or source.find(expected, start + 1) >= 0:
        raise OperationError("source text changed or is ambiguous")
    if replacement == expected:
        return False
    end = start + len(expected)

    cursor = 0
    first_leaf: dict[str, Any] | None = None
    for leaf in leaves:
        text = leaf.get("text", "")
        leaf_start, leaf_end = cursor, cursor + len(text)
        cursor = leaf_end
        overlap_start, overlap_end = max(start, leaf_start), min(end, leaf_end)
        if overlap_start >= overlap_end:
            continue
        if first_leaf is None:
            first_leaf = leaf
            prefix = text[: overlap_start - leaf_start]
            suffix = text[overlap_end - leaf_start :]
            leaf["text"] = prefix + replacement + suffix
        else:
            prefix = text[: overlap_start - leaf_start]
            suffix = text[overlap_end - leaf_start :]
            leaf["text"] = prefix + suffix

    if first_leaf is None:
        raise OperationError("replace_range target contains no text")
    _prune_empty_text(block)
    return True


def _prune_empty_text(node: dict[str, Any]) -> None:
    children = node.get("content")
    if not isinstance(children, list):
        return
    for child in children:
        _prune_empty_text(child)
    node["content"] = [
        child for child in children
        if child.get("type") != "text" or child.get("text") != ""
    ]


def _apply_one(document: dict[str, Any], title: str, operation: dict[str, Any], *, allow_replace_document: bool) -> tuple[str, bool]:
    operation_type = operation.get("type")
    blocks = document["content"]

    if operation_type == "set_title":
        value = operation.get("title")
        if not isinstance(value, str) or not value.strip():
            raise OperationError("set_title requires a non-blank title")
        next_title = value.strip()
        return next_title, next_title != title

    if operation_type == "replace_block":
        return title, _replace_block(document, operation)

    if operation_type == "replace_range":
        return title, _replace_range(document, operation)

    if operation_type == "insert_blocks_after":
        after_id = operation.get("after_block_id")
        inserts = operation.get("blocks")
        if not isinstance(inserts, list) or not inserts:
            raise OperationError("insert_blocks_after requires a non-empty blocks list")
        if after_id is None:
            index = -1
        else:
            index = _top_level_index(document, after_id)
        inserts = deepcopy(inserts)
        # Validate as a temporary document before changing the working copy.
        normalize_document({"type": "doc", "schema_version": 1, "content": inserts})
        existing_ids = {(item.get("attrs") or {}).get("block_id") for item in blocks}
        new_ids = [(item.get("attrs") or {}).get("block_id") for item in inserts]
        if any(item_id in existing_ids for item_id in new_ids):
            raise OperationError("inserted block_id already exists")
        if len(set(new_ids)) != len(new_ids):
            raise OperationError("inserted block_ids must be unique")
        document["content"][index + 1 : index + 1] = inserts
        return title, True

    if operation_type == "delete_blocks":
        block_ids = operation.get("block_ids")
        if not isinstance(block_ids, list) or not block_ids or any(not isinstance(item, str) for item in block_ids):
            raise OperationError("delete_blocks requires block_ids")
        if len(set(block_ids)) != len(block_ids):
            raise OperationError("delete_blocks block_ids must be unique")
        positions = {_top_level_index(document, block_id) for block_id in block_ids}
        document["content"] = [block for index, block in enumerate(blocks) if index not in positions]
        return title, bool(positions)

    if operation_type == "move_block":
        block_id = operation.get("block_id")
        after_id = operation.get("after_block_id")
        original_order = [
            (block.get("attrs") or {}).get("block_id") for block in document["content"]
        ]
        source_index = _top_level_index(document, block_id)
        if after_id == block_id:
            raise OperationError("a block cannot be moved after itself")
        block = document["content"].pop(source_index)
        if after_id is None:
            target_index = 0
        else:
            target_index = _top_level_index(document, after_id) + 1
        document["content"].insert(target_index, block)
        next_order = [
            (item.get("attrs") or {}).get("block_id") for item in document["content"]
        ]
        return title, next_order != original_order

    if operation_type == "replace_document":
        if not allow_replace_document:
            raise OperationError("replace_document requires an explicit full rewrite")
        replacement = operation.get("document")
        if not isinstance(replacement, dict):
            raise OperationError("replace_document requires a document object")
        normalized = normalize_document(replacement)
        changed = normalized != document
        document.clear()
        document.update(normalized)
        return title, changed

    raise OperationError(f"unsupported operation type: {operation_type}")


def apply_operation_batch(
    source_document: dict[str, Any],
    source_title: str,
    operations: list[dict[str, Any]],
    *,
    applied_operations: list[dict[str, str]],
    allow_replace_document: bool = False,
) -> tuple[dict[str, Any], str, list[dict[str, str]], int]:
    """Apply a complete operation batch to a private copy or reject it wholly.

    The returned document is proposal preview state only; callers must persist it
    separately from the authoritative Page. Existing operation IDs are replayed
    as no-ops, while reusing an ID for different content is rejected.
    """
    if not isinstance(operations, list) or len(operations) > MAX_OPERATIONS_PER_BATCH:
        raise OperationError("operation batch must contain at most 100 operations")
    try:
        encoded = json.dumps(operations, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise OperationError("operations must be JSON-compatible") from error
    if len(encoded) > MAX_BATCH_BYTES:
        raise OperationError("operation batch exceeds the 2 MB limit")

    try:
        working_document = normalize_document(source_document)
    except (DocumentValidationError, TypeError, ValueError) as error:
        raise OperationError("source document is invalid") from error
    working_title = source_title
    applied = deepcopy(applied_operations)
    fingerprints = {
        item.get("operation_id"): item.get("fingerprint")
        for item in applied
        if isinstance(item, dict)
    }
    changed = 0

    for operation in operations:
        if not isinstance(operation, dict):
            raise OperationError("each operation must be an object")
        operation_id = operation.get("operation_id")
        if not isinstance(operation_id, str) or not operation_id.strip():
            raise OperationError("each operation requires operation_id")
        fingerprint = _operation_fingerprint(operation)
        previous = fingerprints.get(operation_id)
        if previous is not None:
            if previous != fingerprint:
                raise OperationError("operation_id was reused with different content")
            continue

        working_title, operation_changed = _apply_one(
            working_document,
            working_title,
            operation,
            allow_replace_document=allow_replace_document,
        )
        try:
            working_document = normalize_document(working_document)
        except (DocumentValidationError, TypeError, ValueError) as error:
            raise OperationError("operation produced an invalid document") from error
        if operation_changed:
            changed += 1
        entry = {"operation_id": operation_id, "fingerprint": fingerprint}
        applied.append(entry)
        fingerprints[operation_id] = fingerprint

    return working_document, working_title, applied, changed
