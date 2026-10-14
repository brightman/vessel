from datetime import UTC, datetime
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from vessel_service.auth.router import get_session
from vessel_service.models import Page, PageDirectory, User
from vessel_service.pages.router import current_user

router = APIRouter(prefix="/v1/directories", tags=["directories"])


class DirectoryCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)

    @field_validator("name")
    @classmethod
    def trim_name(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("Directory name cannot be blank")
        return normalized


class DirectoryUpdate(BaseModel):
    name: str = Field(min_length=1, max_length=120)

    @field_validator("name")
    @classmethod
    def trim_name(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("Directory name cannot be blank")
        return normalized


def serialize_directory(directory: PageDirectory) -> dict[str, str]:
    return {
        "directory_id": directory.directory_id,
        "name": directory.name,
        "status": directory.status,
        "created_at": directory.created_at.isoformat(),
        "updated_at": directory.updated_at.isoformat(),
    }


def _directory_or_404(session: Session, owner_id: str, directory_id: str) -> PageDirectory:
    directory = session.scalar(
        select(PageDirectory).where(
            PageDirectory.directory_id == directory_id,
            PageDirectory.owner_user_id == owner_id,
            PageDirectory.status == "active",
        )
    )
    if directory is None:
        raise HTTPException(status_code=404, detail={"code": "DIRECTORY_NOT_FOUND"})
    return directory


@router.get("")
def list_directories(
    user: User = Depends(current_user), session: Session = Depends(get_session)
) -> dict[str, list[dict[str, str]]]:
    directories = session.scalars(
        select(PageDirectory)
        .where(PageDirectory.owner_user_id == user.user_id, PageDirectory.status == "active")
        .order_by(PageDirectory.created_at, PageDirectory.directory_id)
    ).all()
    return {"directories": [serialize_directory(directory) for directory in directories]}


@router.post("", status_code=201)
def create_directory(
    payload: DirectoryCreate,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, dict[str, str]]:
    now = datetime.now(UTC)
    directory = PageDirectory(
        directory_id=str(uuid4()),
        owner_user_id=user.user_id,
        name=payload.name,
        status="active",
        created_at=now,
        updated_at=now,
    )
    session.add(directory)
    session.commit()
    session.refresh(directory)
    return {"directory": serialize_directory(directory)}


@router.get("/{directory_id}")
def get_directory(
    directory_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, dict[str, str]]:
    return {"directory": serialize_directory(_directory_or_404(session, user.user_id, directory_id))}


@router.patch("/{directory_id}")
def rename_directory(
    directory_id: str,
    payload: DirectoryUpdate,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, dict[str, str]]:
    directory = _directory_or_404(session, user.user_id, directory_id)
    directory.name = payload.name
    directory.updated_at = datetime.now(UTC)
    session.commit()
    session.refresh(directory)
    return {"directory": serialize_directory(directory)}


@router.post("/{directory_id}/archive", status_code=204)
def archive_directory(
    directory_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> Response:
    directory = _directory_or_404(session, user.user_id, directory_id)
    now = datetime.now(UTC)
    directory.status = "archived"
    directory.updated_at = now
    session.execute(
        update(Page)
        .where(Page.directory_id == directory_id, Page.owner_user_id == user.user_id)
        .values(directory_id=None, updated_at=now)
    )
    session.commit()
    return Response(status_code=204)
