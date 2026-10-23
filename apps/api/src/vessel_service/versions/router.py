from datetime import UTC, datetime
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from vessel_service.auth.router import get_session
from vessel_service.models import Note, NoteVersion, User
from vessel_service.notes.router import current_user, serialize_note
from vessel_service.spaces.resources import note_for_user

router = APIRouter(prefix="/v1/notes/{note_id}/versions", tags=["note-versions"])


class CheckpointRequest(BaseModel):
    expected_revision: int = Field(ge=1)


class RestoreRequest(BaseModel):
    expected_revision: int = Field(ge=1)


def serialize_version(version: NoteVersion) -> dict[str, object]:
    return {
        "version_id": version.version_id,
        "note_id": version.note_id,
        "revision": version.revision,
        "title": version.title,
        "document": version.document_json,
        "markdown": version.markdown,
        "source": version.source,
        "actor_user_id": version.actor_user_id,
        "run_id": version.run_id,
        "created_at": version.created_at.isoformat(),
    }


@router.get("")
def list_versions(
    note_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, list[dict[str, object]]]:
    note_for_user(session, user, note_id)
    versions = session.scalars(
        select(NoteVersion)
        .where(NoteVersion.note_id == note_id)
        .order_by(NoteVersion.revision.desc())
    ).all()
    return {"versions": [serialize_version(version) for version in versions]}


@router.post("/checkpoint", status_code=201, response_model=None)
def create_checkpoint(
    note_id: str,
    payload: CheckpointRequest,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, dict[str, object]] | JSONResponse:
    note = note_for_user(session, user, note_id, write=True)
    if note.revision != payload.expected_revision:
        raise HTTPException(status_code=409, detail={"code": "NOTE_REVISION_CONFLICT"})
    existing = session.scalar(
        select(NoteVersion).where(
            NoteVersion.note_id == note_id,
            NoteVersion.revision == note.revision,
        )
    )
    if existing:
        return JSONResponse(status_code=200, content={"version": serialize_version(existing)})
    version = NoteVersion(
        version_id=str(uuid4()),
        note_id=note.note_id,
        revision=note.revision,
        title=note.title,
        document_json=note.document_json,
        markdown=note.markdown,
        source="human",
        actor_user_id=user.user_id,
        created_at=datetime.now(UTC),
    )
    session.add(version)
    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        existing = session.scalar(
            select(NoteVersion).where(
                NoteVersion.note_id == note_id,
                NoteVersion.revision == payload.expected_revision,
            )
        )
        if existing:
            return JSONResponse(status_code=200, content={"version": serialize_version(existing)})
        raise
    session.refresh(version)
    return {"version": serialize_version(version)}


@router.post("/{version_id}/restore")
def restore_version(
    note_id: str,
    version_id: str,
    payload: RestoreRequest,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, dict[str, object]]:
    note = note_for_user(session, user, note_id, write=True)
    if note.revision != payload.expected_revision:
        raise HTTPException(status_code=409, detail={"code": "NOTE_REVISION_CONFLICT"})
    source = session.scalar(
        select(NoteVersion).where(
            NoteVersion.version_id == version_id,
            NoteVersion.note_id == note_id,
        )
    )
    if source is None:
        raise HTTPException(status_code=404, detail={"code": "NOTE_VERSION_NOT_FOUND"})
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
            title=source.title,
            document_json=source.document_json,
            markdown=source.markdown,
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
            title=source.title,
            document_json=source.document_json,
            markdown=source.markdown,
            source="restore",
            actor_user_id=user.user_id,
            created_at=now,
        )
    )
    session.commit()
    updated = note_for_user(session, user, note_id)
    return {"note": serialize_note(updated)}
