from typing import Any, Literal

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from vessel_service.auth.router import get_session
from vessel_service.models import Page, User
from vessel_service.pages.router import PageCreate, _create_in_space, current_user, serialize_page
from vessel_service.spaces.permissions import space_access

router = APIRouter(prefix="/v1/spaces/{space_id}/pages", tags=["pages"])


@router.get("")
def list_space_pages(
    space_id: str,
    status: Literal["active", "archived"] = "active",
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, list[dict[str, Any]]]:
    space_access(session, user, space_id)
    pages = session.scalars(select(Page).where(
        Page.space_id == space_id, Page.status == status,
    ).order_by(Page.updated_at.desc(), Page.page_id)).all()
    return {"pages": [serialize_page(page) for page in pages]}


@router.post("", status_code=201)
def create_space_page(
    space_id: str,
    payload: PageCreate,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    return _create_in_space(session, user, space_id, payload)
