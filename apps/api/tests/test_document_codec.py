import pytest

from vessel_service.document.codec import markdown_from_document, markdown_to_document


def test_markdown_parser_round_trips_supported_blocks_and_marks() -> None:
    markdown = """# Market note

Useful **bold** and [source](https://example.test/report).

- [x] Verified
- [ ] Next action

> Keep the evidence attached.

```python
print(1)
```

| Region | Signal |
| --- | --- |
| North America | Growth |
"""

    document = markdown_to_document(markdown)
    types = [node["type"] for node in document["content"]]
    result = markdown_from_document(document)

    assert types == ["heading", "paragraph", "taskList", "blockquote", "codeBlock", "table"]
    assert document["content"][0]["attrs"]["level"] == 1
    assert "**bold**" in result
    assert "[source](https://example.test/report)" in result
    assert "- [x] Verified" in result
    assert "- [ ] Next action" in result
    assert "| North America | Growth |" in result


def test_markdown_import_rejects_unsafe_link_and_image_schemes() -> None:
    with pytest.raises(ValueError, match="Links must use HTTP"):
        markdown_to_document("[click](javascript:alert(1))")
    with pytest.raises(ValueError, match="Image URLs must use HTTP"):
        markdown_to_document("![unsafe](javascript:alert(1))")


def test_private_note_asset_url_round_trips_as_an_image() -> None:
    markdown = "![Private image](/v1/assets/123e4567-e89b-12d3-a456-426614174000/content)"

    document = markdown_to_document(markdown)
    exported = markdown_from_document(document).strip()

    assert document["content"][0]["attrs"]["src"] == "/v1/assets/123e4567-e89b-12d3-a456-426614174000/content"
    assert exported == markdown


def test_table_cells_with_editor_paragraphs_preserve_text_and_marks_in_markdown() -> None:
    document = {
        "type": "doc", "schema_version": 1,
        "content": [{"type": "table", "attrs": {"block_id": "table-test"}, "content": [
            {"type": "tableRow", "content": [
                {"type": "tableHeader", "content": [{"type": "paragraph", "content": [
                    {"type": "text", "text": "Type"}]}]},
                {"type": "tableHeader", "content": [{"type": "paragraph", "content": [
                    {"type": "text", "text": "Content"}]}]},
            ]},
            {"type": "tableRow", "content": [
                {"type": "tableCell", "content": [{"type": "paragraph", "content": [
                    {"type": "text", "text": "Text", "marks": [{"type": "bold"}]}]}]},
                {"type": "tableCell", "content": [
                    {"type": "paragraph", "content": [{"type": "text", "text": "A|B"}]},
                    {"type": "paragraph", "content": [{"type": "text", "text": "Second line"}]},
                ]},
            ]},
        ]}],
    }
    result = markdown_from_document(document)
    assert "| Type | Content |" in result
    assert "| **Text** | A\\|B<br>Second line |" in result
