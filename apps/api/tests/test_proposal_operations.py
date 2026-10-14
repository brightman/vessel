import pytest

from vessel_service.proposals.operations import OperationError, apply_operation_batch


def paragraph(block_id: str, text: str) -> dict:
    return {
        "type": "paragraph",
        "attrs": {"block_id": block_id},
        "content": [{"type": "text", "text": text}],
    }


def document(*blocks: dict) -> dict:
    return {"type": "doc", "schema_version": 1, "content": list(blocks)}


def test_operation_batch_updates_title_and_inserts_block_after_stable_target() -> None:
    original = document(paragraph("block_a", "Opening"), paragraph("block_b", "Closing"))

    next_document, next_title, applied, changed = apply_operation_batch(
        original,
        "Draft",
        [
            {"operation_id": "op_title", "type": "set_title", "title": "  Research  "},
            {
                "operation_id": "op_insert",
                "type": "insert_blocks_after",
                "after_block_id": "block_a",
                "blocks": [
                    {
                        "type": "heading",
                        "attrs": {"block_id": "block_new", "level": 2},
                        "content": [{"type": "text", "text": "Evidence"}],
                    }
                ],
            },
        ],
        applied_operations=[],
    )

    assert next_title == "Research"
    assert [block["attrs"]["block_id"] for block in next_document["content"]] == [
        "block_a", "block_new", "block_b",
    ]
    assert [item["operation_id"] for item in applied] == ["op_title", "op_insert"]
    assert changed == 2
    assert [block["attrs"]["block_id"] for block in original["content"]] == ["block_a", "block_b"]


def test_replaying_the_same_operation_id_is_idempotent() -> None:
    original = document(paragraph("block_a", "Opening"))
    operation = {
        "operation_id": "op_insert",
        "type": "insert_blocks_after",
        "after_block_id": "block_a",
        "blocks": [paragraph("block_new", "Once")],
    }
    first = apply_operation_batch(original, "Draft", [operation], applied_operations=[])
    replay = apply_operation_batch(first[0], first[1], [operation], applied_operations=first[2])

    assert len(replay[0]["content"]) == 2
    assert replay[3] == 0
    assert replay[2] == first[2]


def test_invalid_operation_rejects_the_entire_batch_without_mutating_preview() -> None:
    original = document(paragraph("block_a", "Opening"))
    before = document(paragraph("block_a", "Opening"))

    with pytest.raises(OperationError, match="target block was not found"):
        apply_operation_batch(
            original,
            "Draft",
            [
                {"operation_id": "op_good", "type": "set_title", "title": "Changed"},
                {
                    "operation_id": "op_bad",
                    "type": "delete_blocks",
                    "block_ids": ["missing"],
                },
            ],
            applied_operations=[],
        )

    assert original == before


def test_replace_range_requires_expected_source_text_to_match_once() -> None:
    original = document(paragraph("block_a", "Confirmed total: 10"))

    with pytest.raises(OperationError, match="source text changed"):
        apply_operation_batch(
            original,
            "Draft",
            [{
                "operation_id": "op_replace",
                "type": "replace_range",
                "block_id": "block_a",
                "expected_text": "Confirmed total: 9",
                "replacement": "Confirmed total: 11",
            }],
            applied_operations=[],
        )


def test_move_block_reports_a_change_and_preserves_block_identity() -> None:
    original = document(paragraph("block_a", "A"), paragraph("block_b", "B"))
    moved, _, _, changed = apply_operation_batch(
        original,
        "Draft",
        [{"operation_id": "op_move", "type": "move_block", "block_id": "block_b", "after_block_id": None}],
        applied_operations=[],
    )

    assert [block["attrs"]["block_id"] for block in moved["content"]] == ["block_b", "block_a"]
    assert changed == 1


def test_reusing_an_operation_id_for_different_content_is_rejected() -> None:
    original = document(paragraph("block_a", "A"))
    first = apply_operation_batch(
        original, "Draft", [{"operation_id": "same", "type": "set_title", "title": "One"}], applied_operations=[]
    )

    with pytest.raises(OperationError, match="reused with different content"):
        apply_operation_batch(
            first[0], first[1], [{"operation_id": "same", "type": "set_title", "title": "Two"}], applied_operations=first[2]
        )


def test_replace_document_requires_explicit_full_rewrite_permission() -> None:
    original = document(paragraph("block_a", "A"))
    with pytest.raises(OperationError, match="explicit full rewrite"):
        apply_operation_batch(
            original,
            "Draft",
            [{"operation_id": "op_full", "type": "replace_document", "document": document(paragraph("block_b", "B"))}],
            applied_operations=[],
        )


def test_replace_range_can_cross_inline_mark_boundaries_without_losing_surrounding_text() -> None:
    original = document({
        "type": "paragraph",
        "attrs": {"block_id": "block_a"},
        "content": [
            {"type": "text", "text": "Alpha "},
            {"type": "text", "text": "old", "marks": [{"type": "bold"}]},
            {"type": "text", "text": " value"},
        ],
    })

    updated, _, _, changed = apply_operation_batch(
        original,
        "Draft",
        [{"operation_id": "op_range", "type": "replace_range", "block_id": "block_a", "expected_text": "old value", "replacement": "new value"}],
        applied_operations=[],
    )

    leaves = updated["content"][0]["content"]
    assert "".join(item["text"] for item in leaves) == "Alpha new value"
    assert changed == 1


def test_replacing_range_with_identical_text_is_a_no_op() -> None:
    original = document(paragraph("block_a", "Keep this"))
    updated, _, _, changed = apply_operation_batch(
        original,
        "Draft",
        [{"operation_id": "same-text", "type": "replace_range", "block_id": "block_a", "expected_text": "this", "replacement": "this"}],
        applied_operations=[],
    )

    assert updated == original
    assert changed == 0


def test_replace_block_preserves_stable_id_and_delete_removes_only_requested_blocks() -> None:
    original = document(paragraph("block_a", "A"), paragraph("block_b", "B"))
    updated, _, _, changed = apply_operation_batch(
        original,
        "Draft",
        [
            {
                "operation_id": "replace-a",
                "type": "replace_block",
                "block_id": "block_a",
                "block": {
                    "type": "heading",
                    "attrs": {"block_id": "block_a", "level": 2},
                    "content": [{"type": "text", "text": "Heading"}],
                },
            },
            {"operation_id": "delete-b", "type": "delete_blocks", "block_ids": ["block_b"]},
        ],
        applied_operations=[],
    )

    assert [(item["type"], item["attrs"]["block_id"]) for item in updated["content"]] == [("heading", "block_a")]
    assert changed == 2
