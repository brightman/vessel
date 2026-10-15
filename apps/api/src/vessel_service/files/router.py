"""File API: space-scoped creation, resource-scoped access, current authorization."""

import hashlib
import json
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, Request
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse, Response
from fastapi.routing import APIRoute
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from vessel_service.auth.router import get_session
from vessel_service.models import User
from vessel_service.pages.router import current_user

from .jobs import process_jobs
from .metadata import FileMetadata
from .models import (
    DriveAuditEvent,
    DriveFile,
    DriveFileVersion,
    DriveGrant,
    DriveIdempotencyReceipt,
    DriveItem,
    DrivePurgeJob,
)
from .permissions import access_item, fail, space_role, utc
from .schemas import (
    AddGrant,
    CreateFolder,
    FileSearch,
    MoveCommit,
    MovePrepare,
    PurgeBatch,
    RenameItem,
    RestoreCommit,
    RestorePrepare,
    RevokeGrant,
    TrashItem,
    UpdateGrant,
)
from .storage import FilesSettings, StorageError
from .uploads import (
    CompleteUpload,
    DownloadRequest,
    RestoreVersion,
    SignParts,
    UploadCreate,
    UploadService,
    authorize_upload,
    enqueue,
    row_dict,
    upload_payload,
    version_payload,
)


class FileRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()

        async def wrapped(request):
            request.state.file_request_id = str(uuid4())
            try:
                result = await handler(request)
            except HTTPException as exc:
                result = JSONResponse(
                    {"detail": exc.detail},
                    status_code=exc.status_code,
                    headers=exc.headers,
                )
            except StorageError as exc:
                result = JSONResponse(
                    {"detail": {"code": exc.code}},
                    status_code=503 if exc.code == "FILE_STORAGE_UNAVAILABLE" else 422,
                )
            except IntegrityError:
                result = JSONResponse(
                    {"detail": {"code": "FILE_CONCURRENT_MUTATION"}}, status_code=409
                )
            result.headers["X-Request-ID"] = request.state.file_request_id
            return result

        return wrapped


router = APIRouter(prefix="/v1", tags=["files"], route_class=FileRoute)


def metadata(session, user):
    return FileMetadata(session, user, request_id=session.info.get("file_request_id"))


def storage(request):
    value = getattr(request.app.state, "file_storage", None)
    if value is None:
        fail("FILE_STORAGE_UNAVAILABLE", 503)
    return value


def uploads(request, session, user):
    return UploadService(
        session,
        user,
        storage(request),
        getattr(request.app.state, "file_settings", FilesSettings()),
    )


def read_commit(session, value):
    session.commit()
    return value


def mutate(
    request, session, user, operation, target, payload, authorize, execute, status=200
):
    key = request.headers.get("Idempotency-Key")
    if not key or len(key) > 128:
        fail("IDEMPOTENCY_KEY_REQUIRED", 422)
    session.info["file_request_id"] = getattr(request.state, "file_request_id", None)
    authorize()
    data = (
        payload.model_dump(mode="json", exclude_unset=True)
        if hasattr(payload, "model_dump")
        else payload
    )
    digest = hashlib.sha256(
        json.dumps(data, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    query = select(DriveIdempotencyReceipt).where(
        DriveIdempotencyReceipt.actor_user_id == user.user_id,
        DriveIdempotencyReceipt.operation == operation,
        DriveIdempotencyReceipt.target == target,
        DriveIdempotencyReceipt.key == key,
    )
    receipt = session.scalar(query)
    if receipt and utc(receipt.expires_at) <= datetime.now(UTC):
        session.delete(receipt)
        session.flush()
        receipt = None
    if receipt:
        if receipt.request_hash != digest:
            fail("IDEMPOTENCY_CONFLICT")
        if receipt.status != "done":
            raise HTTPException(
                409,
                detail={"code": "REQUEST_IN_PROGRESS"},
                headers={"Retry-After": "1"},
            )
        result = receipt.response
        code = receipt.status_code
    else:
        receipt = DriveIdempotencyReceipt(
            receipt_id=str(uuid4()),
            actor_user_id=user.user_id,
            operation=operation,
            target=target,
            key=key,
            request_hash=digest,
            status="running",
            expires_at=datetime.now(UTC) + timedelta(days=7),
        )
        session.add(receipt)
        session.flush()
        value = execute()
        if isinstance(value, tuple):
            result, code = value
        else:
            result, code = value, status
        result = jsonable_encoder(result)
        receipt.response = result
        receipt.status_code = code
        receipt.status = "done"
    for event in session.new:
        if isinstance(event, DriveAuditEvent):
            event.request_id = getattr(request.state, "file_request_id", None)
    session.commit()
    if code == 204:
        return Response(status_code=204)
    headers = {}
    if code == 202:
        body = next(iter(result.values()))
        if isinstance(body, dict) and body.get("status_url"):
            headers["Location"] = body["status_url"]
    return JSONResponse(result, status_code=code, headers=headers)


def batch_auth(session, user, batch_id, purge=False):
    from .models import DriveTrashBatch

    batch = session.get(DriveTrashBatch, batch_id)
    if batch is None:
        fail("FILE_TRASH_NOT_FOUND", 404)
    _, role = space_role(session, user, batch.space_id, lock=True)
    if role is None:
        fail("FILE_TRASH_NOT_FOUND", 404)
    allowed = ("owner", "admin") if purge else ("owner", "admin", "editor")
    if role not in allowed:
        fail("FILE_PERMISSION_DENIED", 403)
    return batch


def item_auth(session, user, item_id, action="write", allow_trashed=False):
    return lambda: access_item(session, user, item_id, action, True, allow_trashed)


@router.get("/spaces/{space_id}/folders/root")
def root(
    space_id: str,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return read_commit(session, {"folder": metadata(session, user).root(space_id)})


@router.get("/spaces/{space_id}/file-items")
def items(
    space_id: str,
    parent_folder_id: str | None = None,
    limit: int = Query(50, ge=1, le=200),
    cursor: str | None = None,
    kind: str | None = None,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    svc = metadata(session, user)
    if parent_folder_id is None:
        parent_folder_id = svc.root(space_id)["item_id"]
    folder, _ = access_item(session, user, parent_folder_id)
    if folder.space_id != space_id:
        fail("FOLDER_NOT_FOUND", 404)
    return read_commit(
        session, svc.list_children(parent_folder_id, limit, cursor, kind)
    )


@router.get("/folders/{folder_id}/children")
def children(
    folder_id: str,
    limit: int = Query(50, ge=1, le=200),
    cursor: str | None = None,
    kind: str | None = None,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return read_commit(
        session, metadata(session, user).list_children(folder_id, limit, cursor, kind)
    )


@router.post("/spaces/{space_id}/folders")
def create_folder(
    space_id: str,
    payload: CreateFolder,
    request: Request,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    def auth():
        folder, _ = access_item(
            session, user, payload.parent_folder_id, "create_children", True
        )
        if folder.space_id != space_id:
            fail("FOLDER_NOT_FOUND", 404)

    return mutate(
        request,
        session,
        user,
        "folder.create",
        space_id,
        payload,
        auth,
        lambda: {"folder": metadata(session, user).create_folder(space_id, payload)},
        201,
    )


@router.get("/file-items/{item_id}")
def get_item(
    item_id: str,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return {"item": metadata(session, user).get(item_id)}


@router.patch("/file-items/{item_id}")
def rename(
    item_id: str,
    payload: RenameItem,
    request: Request,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return mutate(
        request,
        session,
        user,
        "item.rename",
        item_id,
        payload,
        item_auth(session, user, item_id),
        lambda: {"item": metadata(session, user).rename(item_id, payload)},
    )


@router.get("/file-items/{item_id}/permissions")
def permissions(
    item_id: str,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return {"permissions": metadata(session, user).permissions(item_id)}


@router.post("/spaces/{space_id}/file-items/search")
def search(
    space_id: str,
    payload: FileSearch,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return read_commit(session, metadata(session, user).search(space_id, payload))


@router.get("/shared-files")
def shared(
    limit: int = Query(50, ge=1, le=200),
    cursor: str | None = None,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return read_commit(session, metadata(session, user).shared_with_me(limit, cursor))


@router.get("/file-items/{item_id}/grants")
def grants(
    item_id: str,
    limit: int = Query(50, ge=1, le=200),
    cursor: str | None = None,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return read_commit(
        session, metadata(session, user).list_grants(item_id, limit, cursor)
    )


@router.post("/file-items/{item_id}/grants")
def add_grant(
    item_id: str,
    payload: AddGrant,
    request: Request,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return mutate(
        request,
        session,
        user,
        "grant.create",
        item_id,
        payload,
        item_auth(session, user, item_id, "manage_sharing"),
        lambda: metadata(session, user).add_grant(item_id, payload),
        201,
    )


@router.patch("/file-items/{item_id}/grants/{grant_id}")
def change_grant(
    item_id: str,
    grant_id: str,
    payload: UpdateGrant,
    request: Request,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return mutate(
        request,
        session,
        user,
        "grant.update",
        item_id + ":" + grant_id,
        payload,
        item_auth(session, user, item_id, "manage_sharing"),
        lambda: metadata(session, user).update_grant(item_id, grant_id, payload),
    )


@router.delete("/file-items/{item_id}/grants/{grant_id}")
def revoke_grant(
    item_id: str,
    grant_id: str,
    payload: RevokeGrant,
    request: Request,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return mutate(
        request,
        session,
        user,
        "grant.revoke",
        item_id + ":" + grant_id,
        payload,
        item_auth(session, user, item_id, "manage_sharing"),
        lambda: metadata(session, user).revoke_grant(item_id, grant_id, payload),
        204,
    )


@router.post("/file-items/{item_id}/move/prepare")
def move_prepare(
    item_id: str,
    payload: MovePrepare,
    request: Request,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return mutate(
        request,
        session,
        user,
        "move.prepare",
        item_id,
        payload,
        item_auth(session, user, item_id, "move"),
        lambda: {"move": metadata(session, user).prepare_move(item_id, payload)},
    )


@router.post("/file-items/{item_id}/move/commit")
def move_commit(
    item_id: str,
    payload: MoveCommit,
    request: Request,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return mutate(
        request,
        session,
        user,
        "move.commit",
        item_id,
        payload,
        item_auth(session, user, item_id, "move"),
        lambda: {"item": metadata(session, user).commit_move(item_id, payload)},
    )


@router.post("/file-items/{item_id}/trash")
def trash(
    item_id: str,
    payload: TrashItem,
    request: Request,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return mutate(
        request,
        session,
        user,
        "item.trash",
        item_id,
        payload,
        item_auth(session, user, item_id, "trash", True),
        lambda: {"trash_batch": metadata(session, user).trash(item_id, payload)},
    )


@router.get("/spaces/{space_id}/file-trash")
def trash_list(
    space_id: str,
    limit: int = Query(50, ge=1, le=200),
    cursor: str | None = None,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return read_commit(
        session, metadata(session, user).list_trash(space_id, limit, cursor)
    )


@router.post("/file-trash/{batch_id}/restore/prepare")
def restore_prepare(
    batch_id: str,
    payload: RestorePrepare,
    request: Request,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    def auth():
        batch_auth(session, user, batch_id)

    return mutate(
        request,
        session,
        user,
        "restore.prepare",
        batch_id,
        payload,
        auth,
        lambda: {"restore": metadata(session, user).prepare_restore(batch_id, payload)},
    )


@router.post("/file-trash/{batch_id}/restore")
def restore(
    batch_id: str,
    payload: RestoreCommit,
    request: Request,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return mutate(
        request,
        session,
        user,
        "restore.commit",
        batch_id,
        payload,
        lambda: batch_auth(session, user, batch_id),
        lambda: metadata(session, user).commit_restore(batch_id, payload),
    )


@router.post("/spaces/{space_id}/file-uploads")
def start_upload(
    space_id: str,
    payload: UploadCreate,
    request: Request,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    def auth():
        target = (
            payload.parent_folder_id if payload.mode == "create" else payload.file_id
        )
        item, _ = access_item(
            session,
            user,
            target,
            "create_children" if payload.mode == "create" else "write",
            True,
        )
        if item.space_id != space_id:
            fail("FILE_NOT_FOUND", 404)

    return mutate(
        request,
        session,
        user,
        "upload.create",
        space_id,
        payload,
        auth,
        lambda: uploads(request, session, user).create(space_id, payload),
        201,
    )


@router.post("/file-uploads/{upload_id}/parts/sign")
def sign_parts(
    upload_id: str,
    payload: SignParts,
    request: Request,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return read_commit(
        session, uploads(request, session, user).sign(upload_id, payload.part_numbers)
    )


@router.get("/file-uploads/{upload_id}")
def upload_status(
    upload_id: str,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return {"upload": upload_payload(authorize_upload(session, user, upload_id, False))}


@router.post("/file-uploads/{upload_id}/complete")
def complete(
    upload_id: str,
    payload: CompleteUpload,
    request: Request,
    background: BackgroundTasks,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    result = mutate(
        request,
        session,
        user,
        "upload.complete",
        upload_id,
        payload,
        lambda: authorize_upload(session, user, upload_id),
        lambda: uploads(request, session, user).complete(upload_id, payload),
    )
    background.add_task(
        process_jobs, request.app.state.session_factory, storage(request)
    )
    return result


@router.post("/file-uploads/{upload_id}/cancel")
def cancel(
    upload_id: str,
    request: Request,
    background: BackgroundTasks,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    result = mutate(
        request,
        session,
        user,
        "upload.cancel",
        upload_id,
        {},
        lambda: authorize_upload(session, user, upload_id),
        lambda: uploads(request, session, user).cancel(upload_id),
    )
    background.add_task(
        process_jobs, request.app.state.session_factory, storage(request)
    )
    return result


@router.post("/files/{file_id}/download")
def download(
    file_id: str,
    payload: DownloadRequest,
    request: Request,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    item, _ = access_item(session, user, file_id)
    if item.kind != "file":
        fail("FILE_NOT_FOUND", 404)
    file = session.get(DriveFile, file_id)
    version_id = payload.version_id or file.current_version_id
    version = session.scalar(
        select(DriveFileVersion).where(
            DriveFileVersion.version_id == version_id,
            DriveFileVersion.item_id == file_id,
        )
    )
    if version is None:
        fail("FILE_VERSION_NOT_FOUND", 404)
    signed = storage(request).sign_download(row_dict(version), item.name)
    return {
        "download": {
            "file_id": file_id,
            "version_id": version.version_id,
            "name": item.name,
            "size_bytes": version.size_bytes,
            "sha256": version.sha256,
            "content_type": version.content_type,
            **signed,
        }
    }


@router.get("/files/{file_id}/versions")
def versions(
    file_id: str,
    limit: int = Query(50, ge=1, le=200),
    cursor: str | None = None,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    item, _ = access_item(session, user, file_id)
    if item.kind != "file":
        fail("FILE_NOT_FOUND", 404)
    rows = list(
        session.scalars(
            select(DriveFileVersion).where(DriveFileVersion.item_id == file_id)
        )
    )
    selected, next_cursor = metadata(session, user).paginate(
        rows, limit, cursor, ["versions", file_id], lambda v: (-v.ordinal, v.version_id)
    )
    return read_commit(
        session,
        {
            "versions": [version_payload(v) for v in selected],
            "next_cursor": next_cursor,
        },
    )


@router.post("/files/{file_id}/versions/{version_id}/restore")
def version_restore(
    file_id: str,
    version_id: str,
    payload: RestoreVersion,
    request: Request,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    return mutate(
        request,
        session,
        user,
        "version.restore",
        file_id + ":" + version_id,
        payload,
        item_auth(session, user, file_id),
        lambda: uploads(request, session, user).restore(
            file_id, version_id, payload.expected_current_version_id
        ),
    )


@router.post("/file-trash/{batch_id}/purge")
def purge(
    batch_id: str,
    payload: PurgeBatch,
    request: Request,
    background: BackgroundTasks,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    def auth():
        batch_auth(session, user, batch_id, True)

    def execute():
        from .models import DriveTrashBatch

        batch = session.get(DriveTrashBatch, batch_id)
        if batch.status != "trashed":
            fail("UPLOAD_STATE_CONFLICT")
        if batch.batch_version != payload.expected_batch_version:
            fail("FILE_METADATA_VERSION_CONFLICT")
        existing = session.scalar(
            select(DrivePurgeJob).where(DrivePurgeJob.batch_id == batch_id)
        )
        if existing:
            return {"purge": purge_json(existing)}, 202
        batch.status = "purging"
        batch.batch_version += 1
        ids = list(
            session.scalars(
                select(DriveItem.item_id).where(DriveItem.trash_batch_id == batch_id)
            )
        )
        for item in session.scalars(
            select(DriveItem).where(DriveItem.item_id.in_(ids))
        ):
            item.status = "purging"
        for grant in session.scalars(
            select(DriveGrant).where(
                DriveGrant.item_id.in_(ids), DriveGrant.revoked_at.is_(None)
            )
        ):
            grant.revoked_at = datetime.now(UTC)
        job = DrivePurgeJob(
            purge_id=str(uuid4()),
            space_id=batch.space_id,
            batch_id=batch_id,
            status="pending",
        )
        session.add(job)
        session.flush()
        enqueue(session, "purge:" + job.purge_id, "purge", {"purge_id": job.purge_id})
        session.add(
            DriveAuditEvent(
                event_id=str(uuid4()),
                space_id=batch.space_id,
                item_id=batch.root_item_id,
                actor_user_id=user.user_id,
                operation="file.purge.request",
            )
        )
        return {"purge": purge_json(job)}, 202

    result = mutate(
        request, session, user, "purge.create", batch_id, payload, auth, execute
    )
    background.add_task(
        process_jobs, request.app.state.session_factory, storage(request)
    )
    return result


def purge_json(job):
    return {
        "purge_id": job.purge_id,
        "space_id": job.space_id,
        "batch_id": job.batch_id,
        "status": job.status,
        "failure_code": job.failure_code,
        "created_at": utc(job.created_at).isoformat(),
        "updated_at": utc(job.updated_at).isoformat(),
        "status_url": f"/v1/file-purges/{job.purge_id}",
    }


@router.get("/file-purges/{purge_id}")
def purge_status(
    purge_id: str,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    job = session.get(DrivePurgeJob, purge_id)
    if not job:
        fail("FILE_PURGE_NOT_FOUND", 404)
    _, role = space_role(session, user, job.space_id)
    if role not in ("owner", "admin"):
        fail("FILE_PERMISSION_DENIED", 403) if role else fail(
            "FILE_PURGE_NOT_FOUND", 404
        )
    return {"purge": purge_json(job)}


@router.get("/spaces/{space_id}/file-audit")
def audit(
    space_id: str,
    limit: int = Query(50, ge=1, le=200),
    cursor: str | None = None,
    session: Session = Depends(get_session),
    user: User = Depends(current_user),
):
    _, role = space_role(session, user, space_id)
    if role not in ("owner", "admin"):
        fail("FILE_PERMISSION_DENIED", 403) if role else fail("SPACE_NOT_FOUND", 404)
    rows = list(
        session.scalars(
            select(DriveAuditEvent).where(DriveAuditEvent.space_id == space_id)
        )
    )
    chosen, next_cursor = metadata(session, user).paginate(
        rows,
        limit,
        cursor,
        ["audit", space_id],
        lambda e: (utc(e.created_at).isoformat(), e.event_id),
    )
    return read_commit(
        session, {"events": [row_dict(e) for e in chosen], "next_cursor": next_cursor}
    )
