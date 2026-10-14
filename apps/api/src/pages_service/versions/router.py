from datetime import UTC, datetime
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from pages_service.auth.router import get_session
from pages_service.models import Page, PageVersion, User
from pages_service.pages.router import _page_or_404, current_user, serialize_page

router = APIRouter(prefix="/v1/pages/{page_id}/versions", tags=["page-versions"])


class CheckpointRequest(BaseModel):
    expected_revision: int = Field(ge=1)


class RestoreRequest(BaseModel):
    expected_revision: int = Field(ge=1)


def serialize_version(version: PageVersion) -> dict[str, object]:
    return {
        "version_id": version.version_id,
        "page_id": version.page_id,
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
    page_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, list[dict[str, object]]]:
    _page_or_404(session, user.user_id, page_id)
    versions = session.scalars(
        select(PageVersion)
        .where(PageVersion.page_id == page_id)
        .order_by(PageVersion.revision.desc())
    ).all()
    return {"versions": [serialize_version(version) for version in versions]}


@router.post("/checkpoint", status_code=201, response_model=None)
def create_checkpoint(
    page_id: str,
    payload: CheckpointRequest,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, dict[str, object]] | JSONResponse:
    page = _page_or_404(session, user.user_id, page_id)
    if page.revision != payload.expected_revision:
        raise HTTPException(status_code=409, detail={"code": "PAGE_REVISION_CONFLICT"})
    existing = session.scalar(
        select(PageVersion).where(
            PageVersion.page_id == page_id,
            PageVersion.revision == page.revision,
        )
    )
    if existing:
        return JSONResponse(status_code=200, content={"version": serialize_version(existing)})
    version = PageVersion(
        version_id=str(uuid4()),
        page_id=page.page_id,
        revision=page.revision,
        title=page.title,
        document_json=page.document_json,
        markdown=page.markdown,
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
            select(PageVersion).where(
                PageVersion.page_id == page_id,
                PageVersion.revision == payload.expected_revision,
            )
        )
        if existing:
            return JSONResponse(status_code=200, content={"version": serialize_version(existing)})
        raise
    session.refresh(version)
    return {"version": serialize_version(version)}


@router.post("/{version_id}/restore")
def restore_version(
    page_id: str,
    version_id: str,
    payload: RestoreRequest,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, dict[str, object]]:
    page = _page_or_404(session, user.user_id, page_id)
    if page.revision != payload.expected_revision:
        raise HTTPException(status_code=409, detail={"code": "PAGE_REVISION_CONFLICT"})
    source = session.scalar(
        select(PageVersion).where(
            PageVersion.version_id == version_id,
            PageVersion.page_id == page_id,
        )
    )
    if source is None:
        raise HTTPException(status_code=404, detail={"code": "PAGE_VERSION_NOT_FOUND"})
    next_revision = page.revision + 1
    now = datetime.now(UTC)
    result = session.execute(
        update(Page)
        .where(
            Page.page_id == page_id,
            Page.owner_user_id == user.user_id,
            Page.status == "active",
            Page.revision == payload.expected_revision,
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
        raise HTTPException(status_code=409, detail={"code": "PAGE_REVISION_CONFLICT"})
    session.add(
        PageVersion(
            version_id=str(uuid4()),
            page_id=page_id,
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
    updated = _page_or_404(session, user.user_id, page_id)
    return {"page": serialize_page(updated)}
