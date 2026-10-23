"""Rename the persisted Page resource to Note without replacing its rows.

Revision ID: 0012_notes_rename
Revises: 0011_registration_email
"""

from collections.abc import Iterator
import json

from alembic import op
import sqlalchemy as sa


revision: str = "0012_notes_rename"
down_revision: str | None = "0011_registration_email"
branch_labels: str | None = None
depends_on: str | None = None


TABLES = (
    ("pages", "notes"),
    ("page_directories", "note_directories"),
    ("page_versions", "note_versions"),
    ("page_proposals", "note_proposals"),
    ("page_capabilities", "note_capabilities"),
    ("page_assets", "note_assets"),
    ("page_agent_events", "note_agent_events"),
)
NOTE_ID_TABLES = (
    "notes", "note_versions", "note_proposals", "note_capabilities",
    "note_assets", "note_agent_events",
)
JSON_FIELDS = (
    ("notes", "note_id", "document_json"),
    ("note_versions", "version_id", "document_json"),
    ("note_proposals", "proposal_id", "operations"),
    ("note_proposals", "proposal_id", "applied_operations"),
    ("note_proposals", "proposal_id", "preview_document"),
    ("note_agent_events", "sequence_id", "payload"),
    ("note_capabilities", "capability_id", "selection_json"),
)


def _names(rows: sa.engine.CursorResult) -> Iterator[str]:
    for row in rows:
        yield row[0]


def _rename_pg_objects() -> None:
    bind = op.get_bind()
    if bind.dialect.name != "postgresql":
        return
    preparer = bind.dialect.identifier_preparer
    for table in (new for _, new in TABLES):
        constraints = list(_names(bind.execute(sa.text("""
            SELECT conname FROM pg_constraint
            WHERE conrelid = to_regclass(:table) AND conname LIKE '%page%'
        """), {"table": table})))
        for old in constraints:
            new = old.replace("pages", "notes").replace("page", "note")
            op.execute(sa.text(
                f"ALTER TABLE {preparer.quote(table)} RENAME CONSTRAINT "
                f"{preparer.quote(old)} TO {preparer.quote(new)}"
            ))
    indexes = list(_names(bind.execute(sa.text("""
        SELECT indexname FROM pg_indexes
        WHERE schemaname = current_schema()
          AND tablename LIKE 'note%'
          AND indexname LIKE '%page%'
    """))))
    for old in indexes:
        new = old.replace("pages", "notes").replace("page", "note")
        op.execute(sa.text(f"ALTER INDEX {preparer.quote(old)} RENAME TO {preparer.quote(new)}"))


def _rename_json(value):
    if isinstance(value, list):
        return [_rename_json(item) for item in value]
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            result[{"page": "note", "pages": "notes", "page_id": "note_id"}.get(key, key)] = _rename_json(item)
        return result
    if value == "pagesImage":
        return "notesImage"
    if isinstance(value, str) and value in {"page:read", "page:propose"}:
        return value.replace("page:", "note:")
    return value


def _rename_pg_payloads() -> None:
    bind = op.get_bind()
    if bind.dialect.name != "postgresql":
        return
    for table, primary_key, column in JSON_FIELDS:
        rows = bind.execute(sa.text(
            f"SELECT {primary_key}, {column} FROM {table} "
            f"WHERE {column}::text LIKE '%page%'"
        )).all()
        for identifier, original in rows:
            if original is None:
                continue
            converted = _rename_json(original)
            if converted != original:
                bind.execute(sa.text(
                    f"UPDATE {table} SET {column} = CAST(:payload AS jsonb) "
                    f"WHERE {primary_key} = :identifier"
                ), {"payload": json.dumps(converted), "identifier": identifier})
    bind.execute(sa.text("""
        UPDATE note_agent_events SET event_type = regexp_replace(event_type, '^page\\.', 'note.')
        WHERE event_type LIKE 'page.%'
    """))
    bind.execute(sa.text("""
        UPDATE note_capabilities SET revoked_at = now()
        WHERE revoked_at IS NULL
    """))


def upgrade() -> None:
    for old, new in TABLES:
        op.rename_table(old, new)
    for table in NOTE_ID_TABLES:
        op.alter_column(table, "page_id", new_column_name="note_id")
    _rename_pg_objects()
    _rename_pg_payloads()


def downgrade() -> None:
    raise RuntimeError("Note rename cannot be reversed safely after writes")
