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
from vessel_service.models import Page, PageDirectory, PageVersion, User
from vessel_service.settings import Settings

router = APIRouter(prefix="/v1/pages", tags=["pages"])


class PageCreate(BaseModel):
    title: str = Field(min_length=1, max_length=256)
    document: dict[str, Any]
    directory_id: str | None = None

    @field_validator("title")
    @classmethod
    def trim_title(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("Page title cannot be blank")
        return normalized


class PageUpdate(BaseModel):
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
            raise ValueError("Page title cannot be blank")
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
        required_scope="pages:session",
    )
    user = session.get(User, claims["sub"]) if claims else None
    if not user or user.status != "active":
        raise HTTPException(status_code=401, detail={"code": "INVALID_ACCESS_TOKEN"})
    return user


def serialize_page(page: Page) -> dict[str, Any]:
    return {
        "page_id": page.page_id,
        "title": page.title,
        "directory_id": page.directory_id,
        "document": page.document_json,
        "markdown": page.markdown,
        "revision": page.revision,
        "status": page.status,
        "created_at": page.created_at.isoformat(),
        "updated_at": page.updated_at.isoformat(),
    }


def _page_or_404(session: Session, owner_id: str, page_id: str) -> Page:
    page = session.scalar(
        select(Page).where(
            Page.page_id == page_id,
            Page.owner_user_id == owner_id,
            Page.status == "active",
        )
    )
    if page is None:
        raise HTTPException(status_code=404, detail={"code": "PAGE_NOT_FOUND"})
    return page


def _normalize_content(document: dict[str, Any]) -> tuple[dict[str, Any], str]:
    try:
        normalized = normalize_document(document)
        markdown = markdown_from_document(normalized)
        return normalized, markdown
    except (DocumentValidationError, TypeError, ValueError) as error:
        raise HTTPException(status_code=422, detail={"code": "PAGE_DOCUMENT_INVALID"}) from error


def _validate_directory(session: Session, owner_id: str, directory_id: str | None) -> None:
    if directory_id is None:
        return
    directory = session.scalar(
        select(PageDirectory.directory_id).where(
            PageDirectory.directory_id == directory_id,
            PageDirectory.owner_user_id == owner_id,
            PageDirectory.status == "active",
        )
    )
    if directory is None:
        raise HTTPException(status_code=404, detail={"code": "DIRECTORY_NOT_FOUND"})


@router.get("")
def list_pages(
    user: User = Depends(current_user), session: Session = Depends(get_session)
) -> dict[str, list[dict[str, Any]]]:
    pages = session.scalars(
        select(Page)
        .where(Page.owner_user_id == user.user_id, Page.status == "active")
        .order_by(Page.updated_at.desc(), Page.page_id)
    ).all()
    return {"pages": [serialize_page(page) for page in pages]}


@router.get("/archived")
def list_archived_pages(
    user: User = Depends(current_user), session: Session = Depends(get_session)
) -> dict[str, list[dict[str, Any]]]:
    pages = session.scalars(
        select(Page)
        .where(Page.owner_user_id == user.user_id, Page.status == "archived")
        .order_by(Page.updated_at.desc(), Page.page_id)
    ).all()
    return {"pages": [serialize_page(page) for page in pages]}


@router.post("", status_code=201)
def create_page(
    payload: PageCreate,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    normalized, markdown = _normalize_content(payload.document)
    _validate_directory(session, user.user_id, payload.directory_id)
    now = datetime.now(UTC)
    page = Page(
        page_id=str(uuid4()),
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
    session.add(page)
    session.add(
        PageVersion(
            version_id=str(uuid4()),
            page_id=page.page_id,
            revision=1,
            title=page.title,
            document_json=normalized,
            markdown=markdown,
            source="human",
            actor_user_id=user.user_id,
            created_at=now,
        )
    )
    session.commit()
    session.refresh(page)
    return {"page": serialize_page(page)}


@router.post("/{page_id}/archive", status_code=204)
def archive_page(
    page_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> Response:
    page = _page_or_404(session, user.user_id, page_id)
    page.status = "archived"
    page.updated_at = datetime.now(UTC)
    session.commit()
    return Response(status_code=204)


@router.post("/{page_id}/restore")
def restore_archived_page(
    page_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    page = session.scalar(
        select(Page).where(
            Page.page_id == page_id,
            Page.owner_user_id == user.user_id,
            Page.status == "archived",
        )
    )
    if page is None:
        raise HTTPException(status_code=404, detail={"code": "PAGE_NOT_FOUND"})
    page.status = "active"
    page.updated_at = datetime.now(UTC)
    session.commit()
    session.refresh(page)
    return {"page": serialize_page(page)}


@router.get("/{page_id}")
def get_page(
    page_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    return {"page": serialize_page(_page_or_404(session, user.user_id, page_id))}


@router.get("/{page_id}/markdown", response_class=PlainTextResponse)
def export_markdown(
    page_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> PlainTextResponse:
    page = _page_or_404(session, user.user_id, page_id)
    safe_title = re.sub(r"[^A-Za-z0-9._-]+", "_", page.title).strip("._-") or "page"
    filename = f"{safe_title[:120]}.md"
    disposition = f'attachment; filename="{filename}"'
    if filename != f"{page.title}.md":
        disposition += f"; filename*=UTF-8''{quote(page.title + '.md', safe='')}"
    return PlainTextResponse(
        page.markdown,
        media_type="text/markdown",
        headers={"Content-Disposition": disposition},
    )


@router.put("/{page_id}/markdown")
def import_markdown(
    page_id: str,
    payload: MarkdownImport,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    page = _page_or_404(session, user.user_id, page_id)
    if page.revision != payload.expected_revision:
        raise HTTPException(status_code=409, detail={"code": "PAGE_REVISION_CONFLICT"})
    try:
        document = markdown_to_document(payload.markdown)
        markdown = markdown_from_document(document)
    except (DocumentValidationError, TypeError, ValueError) as error:
        raise HTTPException(status_code=422, detail={"code": "PAGE_MARKDOWN_INVALID"}) from error
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
            document_json=document,
            markdown=markdown,
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
            title=page.title,
            document_json=document,
            markdown=markdown,
            source="import",
            actor_user_id=user.user_id,
            created_at=now,
        )
    )
    session.commit()
    return {"page": serialize_page(_page_or_404(session, user.user_id, page_id))}


@router.patch("/{page_id}")
def update_page(
    page_id: str,
    payload: PageUpdate,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    page = _page_or_404(session, user.user_id, page_id)
    if page.revision != payload.expected_revision:
        raise HTTPException(status_code=409, detail={"code": "PAGE_REVISION_CONFLICT"})
    values: dict[str, Any] = {
        "revision": page.revision + 1,
        "updated_at": datetime.now(UTC),
    }
    if payload.title is not None:
        values["title"] = payload.title.strip()
    if payload.document is not None:
        normalized, markdown = _normalize_content(payload.document)
        values["document_json"] = normalized
        values["markdown"] = markdown
    if "directory_id" in payload.model_fields_set:
        _validate_directory(session, user.user_id, payload.directory_id)
        values["directory_id"] = payload.directory_id
    result = session.execute(
        update(Page)
        .where(
            Page.page_id == page_id,
            Page.owner_user_id == user.user_id,
            Page.status == "active",
            Page.revision == payload.expected_revision,
        )
        .values(**values)
    )
    if result.rowcount != 1:
        session.rollback()
        raise HTTPException(status_code=409, detail={"code": "PAGE_REVISION_CONFLICT"})
    session.commit()
    updated = _page_or_404(session, user.user_id, page_id)
    return {"page": serialize_page(updated)}
