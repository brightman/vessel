from typing import Any, Literal

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from vessel_service.auth.router import get_session
from vessel_service.models import Note, User
from vessel_service.notes.router import NoteCreate, _create_in_space, current_user, serialize_note
from vessel_service.spaces.permissions import space_access

router = APIRouter(prefix="/v1/spaces/{space_id}/notes", tags=["notes"])


@router.get("")
def list_space_notes(
    space_id: str,
    status: Literal["active", "archived"] = "active",
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, list[dict[str, Any]]]:
    space_access(session, user, space_id)
    notes = session.scalars(select(Note).where(
        Note.space_id == space_id, Note.status == status,
    ).order_by(Note.updated_at.desc(), Note.note_id)).all()
    return {"notes": [serialize_note(note) for note in notes]}


@router.post("", status_code=201)
def create_space_note(
    space_id: str,
    payload: NoteCreate,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    return _create_in_space(session, user, space_id, payload)
