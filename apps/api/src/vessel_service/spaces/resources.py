"""Resolve resource access through its persisted Vessel space."""

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from vessel_service.models import Note, NoteDirectory, User
from vessel_service.spaces.permissions import space_access


def note_for_user(session: Session, user: User, note_id: str, *, write: bool = False, status: str = "active") -> Note:
    note = session.scalar(select(Note).where(Note.note_id == note_id, Note.status == status))
    if note is None:
        raise HTTPException(status_code=404, detail={"code": "NOTE_NOT_FOUND"})
    try:
        space_access(session, user, note.space_id, capability="can_write" if write else "can_read", lock=write)
    except HTTPException as error:
        if error.status_code == 404:
            raise HTTPException(status_code=404, detail={"code": "NOTE_NOT_FOUND"}) from error
        raise
    return note


def directory_for_user(session: Session, user: User, directory_id: str, *, write: bool = False) -> NoteDirectory:
    directory = session.scalar(select(NoteDirectory).where(
        NoteDirectory.directory_id == directory_id, NoteDirectory.status == "active"
    ))
    if directory is None:
        raise HTTPException(status_code=404, detail={"code": "DIRECTORY_NOT_FOUND"})
    try:
        space_access(session, user, directory.space_id, capability="can_write" if write else "can_read", lock=write)
    except HTTPException as error:
        if error.status_code == 404:
            raise HTTPException(status_code=404, detail={"code": "DIRECTORY_NOT_FOUND"}) from error
        raise
    return directory
