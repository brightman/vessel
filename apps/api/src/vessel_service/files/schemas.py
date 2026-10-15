"""Strict transport input schemas for metadata and persistent mutations."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class FileInput(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CreateFolder(FileInput):
    name: str
    parent_folder_id: str


class RenameItem(FileInput):
    name: str
    expected_metadata_version: int = Field(ge=1)


class FileSearch(FileInput):
    name_contains: str | None = None
    kind: Literal["file", "folder"] | None = None
    limit: int = Field(default=50, ge=1, le=200)
    cursor: str | None = None


class AddGrant(FileInput):
    grantee_user_id: str
    role: Literal["viewer", "editor"]
    expires_at: datetime | None = None
    expected_acl_revision: int = Field(ge=1)


class UpdateGrant(FileInput):
    role: Literal["viewer", "editor"] | None = None
    expires_at: datetime | None = None
    expected_acl_revision: int = Field(ge=1)


class RevokeGrant(FileInput):
    expected_acl_revision: int = Field(ge=1)


class MovePrepare(FileInput):
    target_parent_folder_id: str
    name: str | None = None
    expected_metadata_version: int = Field(ge=1)


class MoveCommit(FileInput):
    preview_id: str
    preview_hash: str
    expected_metadata_version: int = Field(ge=1)
    expected_acl_revision: int = Field(ge=1)


class TrashItem(FileInput):
    expected_metadata_version: int = Field(ge=1)


class RestorePrepare(FileInput):
    target_parent_folder_id: str | None = None
    name: str | None = None


class RestoreCommit(FileInput):
    preview_id: str
    preview_hash: str
    expected_acl_revision: int = Field(ge=1)


class PurgeBatch(FileInput):
    expected_batch_version: int = Field(ge=1)
