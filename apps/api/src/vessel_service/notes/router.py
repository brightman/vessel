from datetime import UTC, datetime
import re
from urllib.parse import quote
from typing import Any
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Response
from fastapi.responses import PlainTextResponse
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from vessel_service.auth.router import bearer, get_keyring, get_session, get_settings
from vessel_service.auth.tokens import KeyRing
from vessel_service.document.codec import (
    DocumentValidationError,
    markdown_from_document,
    markdown_to_document,
    normalize_document,
)
from vessel_service.models import Note, NoteDirectory, NoteVersion, User
from vessel_service.settings import Settings
from vessel_service.spaces.permissions import personal_space, space_access
from vessel_service.spaces.resources import note_for_user

router = APIRouter(prefix="/v1/notes", tags=["notes"])


class NoteCreate(BaseModel):
    title: str = Field(min_length=1, max_length=256)
    document: dict[str, Any]
    directory_id: str | None = None

    @field_validator("title")
    @classmethod
    def trim_title(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("Note title cannot be blank")
        return normalized


class NoteUpdate(BaseModel):
    expected_revision: int = Field(ge=1)
    title: str | None = Field(default=None, min_length=1, max_length=256)
    document: dict[str, Any] | None = None
    directory_id: str | None = None

    @field_validator("title")
    @classmethod
    def trim_title(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip()
        if not normalized:
            raise ValueError("Note title cannot be blank")
        return normalized


class MarkdownImport(BaseModel):
    expected_revision: int = Field(ge=1)
    markdown: str = Field(max_length=2_000_000)


def current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
    settings: Settings = Depends(get_settings),
    keyring: KeyRing = Depends(get_keyring),
    session: Session = Depends(get_session),
) -> User:
    if not credentials:
        raise HTTPException(status_code=401, detail={"code": "AUTHENTICATION_REQUIRED"})
    claims = keyring.verify(
        credentials.credentials,
        issuer=settings.issuer_url,
        audience="vessel-api",
        required_scope="vessel:session",
    )
    user = session.get(User, claims["sub"]) if claims else None
    if not user or user.status != "active":
        raise HTTPException(status_code=401, detail={"code": "INVALID_ACCESS_TOKEN"})
    return user


def serialize_note(note: Note) -> dict[str, Any]:
    return {
        "note_id": note.note_id,
        "space_id": note.space_id,
        "title": note.title,
        "directory_id": note.directory_id,
        "document": note.document_json,
        "markdown": note.markdown,
        "revision": note.revision,
        "status": note.status,
        "created_at": note.created_at.isoformat(),
        "updated_at": note.updated_at.isoformat(),
    }


def _note_or_404(session: Session, owner_id: str, note_id: str) -> Note:
    note = session.scalar(
        select(Note).where(
            Note.note_id == note_id,
            Note.owner_user_id == owner_id,
            Note.status == "active",
        )
    )
    if note is None:
        raise HTTPException(status_code=404, detail={"code": "NOTE_NOT_FOUND"})
    return note


def _normalize_content(document: dict[str, Any]) -> tuple[dict[str, Any], str]:
    try:
        normalized = normalize_document(document)
        markdown = markdown_from_document(normalized)
        return normalized, markdown
    except (DocumentValidationError, TypeError, ValueError) as error:
        raise HTTPException(status_code=422, detail={"code": "NOTE_DOCUMENT_INVALID"}) from error


def _validate_directory(session: Session, space_id: str, directory_id: str | None) -> None:
    if directory_id is None:
        return
    directory = session.scalar(
        select(NoteDirectory.directory_id).where(
            NoteDirectory.directory_id == directory_id,
            NoteDirectory.space_id == space_id,
            NoteDirectory.status == "active",
        )
    )
    if directory is None:
        raise HTTPException(status_code=404, detail={"code": "DIRECTORY_NOT_FOUND"})


@router.get("")
def list_notes(
    user: User = Depends(current_user), session: Session = Depends(get_session)
) -> dict[str, list[dict[str, Any]]]:
    space = personal_space(session, user)
    notes = session.scalars(
        select(Note)
        .where(Note.space_id == space.space_id, Note.status == "active")
        .order_by(Note.updated_at.desc(), Note.note_id)
    ).all()
    return {"notes": [serialize_note(note) for note in notes]}


@router.get("/archived")
def list_archived_notes(
    user: User = Depends(current_user), session: Session = Depends(get_session)
) -> dict[str, list[dict[str, Any]]]:
    space = personal_space(session, user)
    notes = session.scalars(
        select(Note)
        .where(Note.space_id == space.space_id, Note.status == "archived")
        .order_by(Note.updated_at.desc(), Note.note_id)
    ).all()
    return {"notes": [serialize_note(note) for note in notes]}


@router.post("", status_code=201)
def create_note(
    payload: NoteCreate,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    return _create_in_space(session, user, personal_space(session, user).space_id, payload)


def _create_in_space(session: Session, user: User, space_id: str, payload: NoteCreate) -> dict[str, Any]:
    space_access(session, user, space_id, capability="can_write", lock=True)
    normalized, markdown = _normalize_content(payload.document)
    _validate_directory(session, space_id, payload.directory_id)
    now = datetime.now(UTC)
    note = Note(
        note_id=str(uuid4()),
        space_id=space_id,
        owner_user_id=user.user_id,
        directory_id=payload.directory_id,
        title=payload.title,
        document_json=normalized,
        markdown=markdown,
        revision=1,
        status="active",
        created_at=now,
        updated_at=now,
    )
    session.add(note)
    session.add(
        NoteVersion(
            version_id=str(uuid4()),
            note_id=note.note_id,
            revision=1,
            title=note.title,
            document_json=normalized,
            markdown=markdown,
            source="human",
            actor_user_id=user.user_id,
            created_at=now,
        )
    )
    session.commit()
    session.refresh(note)
    return {"note": serialize_note(note)}


@router.post("/{note_id}/archive", status_code=204)
def archive_note(
    note_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> Response:
    note = note_for_user(session, user, note_id, write=True)
    note.status = "archived"
    note.updated_at = datetime.now(UTC)
    session.commit()
    return Response(status_code=204)


@router.post("/{note_id}/restore")
def restore_archived_note(
    note_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    note = note_for_user(session, user, note_id, write=True, status="archived")
    note.status = "active"
    note.updated_at = datetime.now(UTC)
    session.commit()
    session.refresh(note)
    return {"note": serialize_note(note)}


@router.get("/{note_id}")
def get_note(
    note_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    return {"note": serialize_note(note_for_user(session, user, note_id))}


@router.get("/{note_id}/markdown", response_class=PlainTextResponse)
def export_markdown(
    note_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> PlainTextResponse:
    note = note_for_user(session, user, note_id)
    safe_title = re.sub(r"[^A-Za-z0-9._-]+", "_", note.title).strip("._-") or "note"
    filename = f"{safe_title[:120]}.md"
    disposition = f'attachment; filename="{filename}"'
    if filename != f"{note.title}.md":
        disposition += f"; filename*=UTF-8''{quote(note.title + '.md', safe='')}"
    return PlainTextResponse(
        note.markdown,
        media_type="text/markdown",
        headers={"Content-Disposition": disposition},
    )


@router.put("/{note_id}/markdown")
def import_markdown(
    note_id: str,
    payload: MarkdownImport,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    note = note_for_user(session, user, note_id, write=True)
    if note.revision != payload.expected_revision:
        raise HTTPException(status_code=409, detail={"code": "NOTE_REVISION_CONFLICT"})
    try:
        document = markdown_to_document(payload.markdown)
        markdown = markdown_from_document(document)
    except (DocumentValidationError, TypeError, ValueError) as error:
        raise HTTPException(status_code=422, detail={"code": "NOTE_MARKDOWN_INVALID"}) from error
    next_revision = note.revision + 1
    now = datetime.now(UTC)
    result = session.execute(
        update(Note)
        .where(
            Note.note_id == note_id,
            Note.space_id == note.space_id,
            Note.status == "active",
            Note.revision == payload.expected_revision,
        )
        .values(
            document_json=document,
            markdown=markdown,
            revision=next_revision,
            updated_at=now,
        )
    )
    if result.rowcount != 1:
        session.rollback()
        raise HTTPException(status_code=409, detail={"code": "NOTE_REVISION_CONFLICT"})
    session.add(
        NoteVersion(
            version_id=str(uuid4()),
            note_id=note_id,
            revision=next_revision,
            title=note.title,
            document_json=document,
            markdown=markdown,
            source="import",
            actor_user_id=user.user_id,
            created_at=now,
        )
    )
    session.commit()
    return {"note": serialize_note(note_for_user(session, user, note_id))}


@router.patch("/{note_id}")
def update_note(
    note_id: str,
    payload: NoteUpdate,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    note = note_for_user(session, user, note_id, write=True)
    if note.revision != payload.expected_revision:
        raise HTTPException(status_code=409, detail={"code": "NOTE_REVISION_CONFLICT"})
    values: dict[str, Any] = {
        "revision": note.revision + 1,
        "updated_at": datetime.now(UTC),
    }
    if payload.title is not None:
        values["title"] = payload.title.strip()
    if payload.document is not None:
        normalized, markdown = _normalize_content(payload.document)
        values["document_json"] = normalized
        values["markdown"] = markdown
    if "directory_id" in payload.model_fields_set:
        _validate_directory(session, note.space_id, payload.directory_id)
        values["directory_id"] = payload.directory_id
    result = session.execute(
        update(Note)
        .where(
            Note.note_id == note_id,
            Note.space_id == note.space_id,
            Note.status == "active",
            Note.revision == payload.expected_revision,
        )
        .values(**values)
    )
    if result.rowcount != 1:
        session.rollback()
        raise HTTPException(status_code=409, detail={"code": "NOTE_REVISION_CONFLICT"})
    session.commit()
    updated = note_for_user(session, user, note_id)
    return {"note": serialize_note(updated)}
