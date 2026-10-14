import hashlib
from datetime import UTC, datetime
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response
from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from vessel_service.assets.storage import LocalAssetStorage
from vessel_service.auth.router import get_session, get_settings
from vessel_service.models import Page, PageAsset, User
from vessel_service.pages.router import current_user
from vessel_service.spaces.resources import page_for_user
from vessel_service.settings import Settings

router = APIRouter(prefix="/v1", tags=["assets"])

_IMAGE_SIGNATURES = {
    "image/png": lambda content: content.startswith(b"\x89PNG\r\n\x1a\n"),
    "image/jpeg": lambda content: content.startswith(b"\xff\xd8\xff"),
    "image/gif": lambda content: content.startswith((b"GIF87a", b"GIF89a")),
    "image/webp": lambda content: len(content) >= 12
    and content[:4] == b"RIFF"
    and content[8:12] == b"WEBP",
}


def get_asset_storage(request: Request) -> LocalAssetStorage:
    storage = request.app.state.asset_storage
    if storage is None:
        raise HTTPException(status_code=503, detail={"code": "ASSET_STORAGE_NOT_CONFIGURED"})
    return storage


def _media_type(request: Request) -> str:
    declared = request.headers.get("content-type", "").split(";", maxsplit=1)[0].strip().lower()
    if declared not in _IMAGE_SIGNATURES:
        raise HTTPException(status_code=415, detail={"code": "ASSET_MEDIA_TYPE_NOT_ALLOWED"})
    return declared


async def _read_bounded_body(request: Request, max_bytes: int) -> bytes:
    content_length = request.headers.get("content-length")
    if content_length:
        try:
            if int(content_length) > max_bytes:
                raise HTTPException(status_code=413, detail={"code": "ASSET_TOO_LARGE"})
        except ValueError as error:
            raise HTTPException(status_code=400, detail={"code": "ASSET_LENGTH_INVALID"}) from error
    body = bytearray()
    async for chunk in request.stream():
        if len(body) + len(chunk) > max_bytes:
            raise HTTPException(status_code=413, detail={"code": "ASSET_TOO_LARGE"})
        body.extend(chunk)
    return bytes(body)


def _asset_not_found() -> HTTPException:
    return HTTPException(status_code=404, detail={"code": "ASSET_NOT_FOUND"})


@router.post("/pages/{page_id}/assets", status_code=201)
async def upload_page_asset(
    page_id: str,
    request: Request,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    storage: LocalAssetStorage = Depends(get_asset_storage),
) -> dict[str, dict[str, str | int]]:
    content_type = _media_type(request)
    content = await _read_bounded_body(request, settings.max_asset_upload_bytes)
    if not content or not _IMAGE_SIGNATURES[content_type](content):
        raise HTTPException(status_code=415, detail={"code": "ASSET_CONTENT_TYPE_MISMATCH"})
    page = page_for_user(session, user, page_id, write=True)

    asset_id = str(uuid4())
    object_key = storage.make_key(page.space_id, page_id, asset_id)
    checksum = hashlib.sha256(content).hexdigest()
    asset = PageAsset(
        asset_id=asset_id,
        owner_user_id=user.user_id,
        page_id=page_id,
        object_key=object_key,
        content_type=content_type,
        size_bytes=len(content),
        sha256=checksum,
        created_at=datetime.now(UTC),
    )
    storage.write(object_key, content)
    session.add(asset)
    try:
        session.commit()
    except SQLAlchemyError:
        session.rollback()
        storage.delete(object_key)
        raise
    return {
        "asset": {
            "asset_id": asset_id,
            "page_id": page_id,
            "content_type": content_type,
            "size_bytes": len(content),
            "sha256": checksum,
            "content_url": f"/v1/assets/{asset_id}/content",
        }
    }


@router.get("/assets/{asset_id}/content", name="read_asset_content")
def read_asset_content(
    asset_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
    storage: LocalAssetStorage = Depends(get_asset_storage),
) -> Response:
    asset = session.scalar(select(PageAsset).where(PageAsset.asset_id == asset_id))
    if asset is None:
        raise _asset_not_found()
    try:
        page_for_user(session, user, asset.page_id)
    except HTTPException as error:
        if error.status_code == 404:
            raise _asset_not_found() from error
        raise
    try:
        content = storage.read(asset.object_key)
    except (FileNotFoundError, ValueError):
        raise _asset_not_found()
    return Response(
        content=content,
        media_type=asset.content_type,
        headers={
            "Cache-Control": "private, no-store",
            "ETag": f'"{asset.sha256}"',
            "X-Content-Type-Options": "nosniff",
        },
    )
