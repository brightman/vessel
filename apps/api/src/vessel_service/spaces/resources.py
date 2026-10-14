"""Resolve resource access through its persisted Vessel space."""

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from vessel_service.models import Page, PageDirectory, User
from vessel_service.spaces.permissions import space_access


def page_for_user(session: Session, user: User, page_id: str, *, write: bool = False, status: str = "active") -> Page:
    page = session.scalar(select(Page).where(Page.page_id == page_id, Page.status == status))
    if page is None:
        raise HTTPException(status_code=404, detail={"code": "PAGE_NOT_FOUND"})
    try:
        space_access(session, user, page.space_id, capability="can_write" if write else "can_read", lock=write)
    except HTTPException as error:
        if error.status_code == 404:
            raise HTTPException(status_code=404, detail={"code": "PAGE_NOT_FOUND"}) from error
        raise
    return page


def directory_for_user(session: Session, user: User, directory_id: str, *, write: bool = False) -> PageDirectory:
    directory = session.scalar(select(PageDirectory).where(
        PageDirectory.directory_id == directory_id, PageDirectory.status == "active"
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
