"""Transactional metadata operations. Caller owns commit/rollback."""

import hashlib
import json
import unicodedata
from datetime import datetime, timedelta
from uuid import uuid4

from fastapi.encoders import jsonable_encoder
from sqlalchemy import and_, literal, or_, select

from vessel_service.models import Space, User

from .models import *
from .permissions import (
    access_item,
    ancestors,
    fail,
    space_role,
    utc,
    visible_items_query,
)


def uid():
    return str(uuid4())


def payload(value):
    return (
        value.model_dump(exclude_unset=True)
        if hasattr(value, "model_dump")
        else dict(value)
    )


def normalize(name):
    name = unicodedata.normalize("NFC", name)
    if (
        not name.strip()
        or name in (".", "..")
        or len(name.encode()) > 255
        or any(c in "/\\" or unicodedata.category(c).startswith("C") for c in name)
    ):
        fail("FILE_NAME_INVALID", 422)
    return name, name.casefold()


def item_json(item, session):
    result = {
        k: getattr(item, k)
        for k in (
            "item_id",
            "space_id",
            "kind",
            "name",
            "metadata_version",
            "status",
            "created_by_user_id",
            "updated_by_user_id",
            "created_at",
            "updated_at",
        )
    }
    for key in ("created_at", "updated_at"):
        result[key] = utc(result[key])
    result["parent_folder_id"] = item.parent_id
    if item.kind == "folder":
        result["folder_id"] = item.item_id
    else:
        f = session.get(DriveFile, item.item_id)
        v = (
            session.get(DriveFileVersion, f.current_version_id)
            if f and f.current_version_id
            else None
        )
        result.update(
            current_version_id=f.current_version_id if f else None,
            size_bytes=v.size_bytes if v else None,
            sha256=v.sha256 if v else None,
            content_type=v.content_type if v else None,
        )
    return result


def batch_json(b):
    result = {
        k: getattr(b, k)
        for k in (
            "batch_id",
            "space_id",
            "root_item_id",
            "original_parent_folder_id",
            "status",
            "batch_version",
            "trashed_at",
            "retention_until",
        )
    }
    for key in ("trashed_at", "retention_until"):
        result[key] = utc(result[key])
    return result


class FileMetadata:
    def __init__(self, session, user, request_id=None):
        self.session = session
        self.user = user
        self.request_id = request_id

    def state(self, space_id):
        state = self.session.get(DriveSpaceState, space_id)
        if state is None:
            self.root(space_id)
            state = self.session.get(DriveSpaceState, space_id)
        return state

    def audit(self, item, operation, before=None):
        self.session.add(
            DriveAuditEvent(
                event_id=uid(),
                space_id=item.space_id,
                item_id=item.item_id,
                actor_user_id=self.user.user_id,
                operation=operation,
                before_version=before,
                after_version=item.metadata_version,
                request_id=self.request_id,
            )
        )

    def touch(self, item, operation):
        before = item.metadata_version
        item.metadata_version += 1
        item.updated_by_user_id = self.user.user_id
        item.updated_at = now()
        self.audit(item, operation, before)

    def root(self, space_id):
        space, role = space_role(self.session, self.user, space_id, True)
        if role is None:
            fail("SPACE_NOT_FOUND", 404)
        state = self.session.get(DriveSpaceState, space_id)
        if state:
            return item_json(
                self.session.get(DriveItem, state.root_item_id), self.session
            )
        item = DriveItem(
            item_id=uid(),
            space_id=space_id,
            kind="folder",
            parent_id=None,
            name="Root",
            normalized_name="root",
            created_by_user_id=self.user.user_id,
            updated_by_user_id=self.user.user_id,
        )
        self.session.add(item)
        self.session.flush()
        self.session.add(DriveSpaceState(space_id=space_id, root_item_id=item.item_id))
        self.session.flush()
        return item_json(item, self.session)

    def get(self, item_id):
        return item_json(access_item(self.session, self.user, item_id)[0], self.session)

    def permissions(self, item_id):
        return access_item(self.session, self.user, item_id)[1]

    def paginate(self, rows, limit, cursor, binding, key):
        if not 1 <= limit <= 200:
            fail("FILE_QUERY_INVALID", 422)
        rows = sorted(rows, key=key)
        bind = hashlib.sha256(
            json.dumps([self.user.user_id, binding], sort_keys=True).encode()
        ).hexdigest()
        if cursor:
            record = self.session.get(DriveOperationPreview, cursor)
            if (
                record is None
                or record.kind != "cursor"
                or record.actor_user_id != self.user.user_id
                or utc(record.expires_at) <= now()
                or record.payload["binding"] != bind
            ):
                fail("CURSOR_INVALID", 422)
            marker = tuple(record.payload["last"])
            rows = [r for r in rows if key(r) > marker]
        selected = rows[:limit]
        next_cursor = None
        if len(rows) > limit:
            next_cursor = uid()
            self.session.add(
                DriveOperationPreview(
                    preview_id=next_cursor,
                    actor_user_id=self.user.user_id,
                    space_id="",
                    kind="cursor",
                    item_id="",
                    preview_hash=bind,
                    payload={"binding": bind, "last": list(key(selected[-1]))},
                    expires_at=now() + timedelta(days=1),
                )
            )
            self.session.flush()
        return selected, next_cursor

    def page(self, rows, limit=50, cursor=None, binding=None):
        selected, next_cursor = self.paginate(
            rows, limit, cursor, binding, lambda i: (i.normalized_name, i.item_id)
        )
        return {
            "items": [item_json(r, self.session) for r in selected],
            "next_cursor": next_cursor,
        }

    def page_query(self, query, limit=50, cursor=None, binding=None):
        if not 1 <= limit <= 200:
            fail("FILE_QUERY_INVALID", 422)
        bind = hashlib.sha256(
            json.dumps([self.user.user_id, binding], sort_keys=True).encode()
        ).hexdigest()
        if cursor:
            record = self.session.get(DriveOperationPreview, cursor)
            if (
                record is None
                or record.kind != "cursor"
                or record.actor_user_id != self.user.user_id
                or utc(record.expires_at) <= now()
                or record.payload["binding"] != bind
            ):
                fail("CURSOR_INVALID", 422)
            name, item_id = record.payload["last"]
            query = query.where(
                or_(
                    DriveItem.normalized_name > name,
                    and_(
                        DriveItem.normalized_name == name, DriveItem.item_id > item_id
                    ),
                )
            )
        rows = self.session.scalars(
            query.order_by(DriveItem.normalized_name, DriveItem.item_id).limit(
                limit + 1
            )
        ).all()
        next_cursor = None
        if len(rows) > limit:
            rows = rows[:limit]
            last = rows[-1]
            next_cursor = uid()
            self.session.add(
                DriveOperationPreview(
                    preview_id=next_cursor,
                    actor_user_id=self.user.user_id,
                    space_id="",
                    kind="cursor",
                    item_id="",
                    preview_hash=bind,
                    payload={
                        "binding": bind,
                        "last": [last.normalized_name, last.item_id],
                    },
                    expires_at=now() + timedelta(days=1),
                )
            )
            self.session.flush()
        return {
            "items": [item_json(row, self.session) for row in rows],
            "next_cursor": next_cursor,
        }

    def list_children(self, folder_id, limit=50, cursor=None, kind=None):
        folder, _ = access_item(self.session, self.user, folder_id)
        if folder.kind != "folder":
            fail("FOLDER_NOT_FOUND", 404)
        if kind not in (None, "file", "folder"):
            fail("FILE_QUERY_INVALID", 422)
        query = visible_items_query(self.session, self.user, folder.space_id).where(
            DriveItem.parent_id == folder_id
        )
        if kind:
            query = query.where(DriveItem.kind == kind)
        return self.page_query(query, limit, cursor, ["children", folder_id, kind])

    def search(self, space_id, filters):
        p = payload(filters)
        if not p.get("name_contains") and not p.get("kind"):
            fail("FILE_QUERY_INVALID", 422)
        if p.get("kind") not in (None, "file", "folder"):
            fail("FILE_QUERY_INVALID", 422)
        query = visible_items_query(self.session, self.user, space_id).where(
            DriveItem.parent_id.is_not(None)
        )
        if p.get("kind"):
            query = query.where(DriveItem.kind == p["kind"])
        if p.get("name_contains"):
            query = query.where(
                DriveItem.normalized_name.contains(
                    unicodedata.normalize("NFC", p["name_contains"]).casefold(),
                    autoescape=True,
                )
            )
        return self.page_query(
            query,
            p.get("limit", 50),
            p.get("cursor"),
            ["search", space_id, p.get("kind"), p.get("name_contains")],
        )

    def parent(self, parent_id, space_id, action="create_children"):
        try:
            folder, caps = access_item(self.session, self.user, parent_id, action, True)
        except Exception as e:
            if getattr(e, "status_code", None) == 404:
                fail("FOLDER_NOT_FOUND", 404)
            raise
        if folder.space_id != space_id or folder.kind != "folder":
            fail("FOLDER_NOT_FOUND", 404)
        return folder

    def unique(self, parent_id, name, exclude=None):
        row = self.session.scalar(
            select(DriveItem).where(
                DriveItem.parent_id == parent_id,
                DriveItem.normalized_name == name,
                DriveItem.status == "active",
                DriveItem.item_id != exclude if exclude else True,
            )
        )
        if row:
            fail("ITEM_NAME_CONFLICT")

    def expected(self, item, p):
        if p.get("expected_metadata_version") != item.metadata_version:
            fail("FILE_METADATA_VERSION_CONFLICT")

    def create_folder(self, space_id, values):
        p = payload(values)
        parent = self.parent(p["parent_folder_id"], space_id)
        name, norm = normalize(p["name"])
        if len(ancestors(self.session, parent)) >= 33:
            fail("FILE_HIERARCHY_INVALID", 422)
        self.unique(parent.item_id, norm)
        item = DriveItem(
            item_id=uid(),
            space_id=space_id,
            kind="folder",
            parent_id=parent.item_id,
            name=name,
            normalized_name=norm,
            created_by_user_id=self.user.user_id,
            updated_by_user_id=self.user.user_id,
        )
        self.session.add(item)
        self.session.flush()
        self.audit(item, "create_folder")
        return item_json(item, self.session)

    def rename(self, item_id, values):
        p = payload(values)
        item, _ = access_item(self.session, self.user, item_id, "write", True)
        if item.parent_id is None:
            fail("FILE_PERMISSION_DENIED", 403)
        self.expected(item, p)
        name, norm = normalize(p["name"])
        self.unique(item.parent_id, norm, item_id)
        item.name = name
        item.normalized_name = norm
        self.touch(item, "rename")
        self.session.flush()
        return item_json(item, self.session)

    def acl(self, item, p):
        state = self.state(item.space_id)
        if state.acl_revision != p.get("expected_acl_revision"):
            fail("FILE_ACL_REVISION_CONFLICT")
        return state

    def grant_json(self, g, item_id):
        return {
            "grant_id": g.grant_id,
            "item_id": item_id,
            "grantee_user_id": g.user_id,
            "role": g.role,
            "expires_at": utc(g.expires_at) if g.expires_at else None,
            "created_by_user_id": g.created_by_user_id,
            "created_at": utc(g.created_at),
            "inherited": g.item_id != item_id,
            "source_item_id": g.item_id,
        }

    def list_grants(self, item_id, limit=50, cursor=None):
        item, _ = access_item(self.session, self.user, item_id, "manage_sharing")
        ids = [i.item_id for i in ancestors(self.session, item)]
        grants = self.session.scalars(
            select(DriveGrant).where(
                DriveGrant.item_id.in_(ids), DriveGrant.revoked_at.is_(None)
            )
        ).all()
        selected, next_cursor = self.paginate(
            grants,
            limit,
            cursor,
            ["grants", item_id],
            lambda g: (utc(g.created_at).isoformat(), g.grant_id),
        )
        return {
            "grants": [self.grant_json(g, item_id) for g in selected],
            "acl_revision": self.state(item.space_id).acl_revision,
            "next_cursor": next_cursor,
        }

    grants = list_grants

    def validate_grant(self, p):
        if p.get("role") not in ("viewer", "editor"):
            fail("SHARE_TARGET_UNAVAILABLE", 422)
        expiry = p.get("expires_at")
        if isinstance(expiry, str):
            expiry = datetime.fromisoformat(expiry.replace("Z", "+00:00"))
        if expiry and utc(expiry) <= now():
            fail("SHARE_TARGET_UNAVAILABLE", 422)
        return expiry

    def add_grant(self, item_id, values):
        p = payload(values)
        item, _ = access_item(self.session, self.user, item_id, "manage_sharing", True)
        state = self.acl(item, p)
        expiry = self.validate_grant(p)
        actor = self.session.scalar(
            select(User)
            .where(User.user_id == p["grantee_user_id"])
            .execution_options(populate_existing=True)
        )
        if actor is None or actor.status != "active":
            fail("SHARE_TARGET_UNAVAILABLE", 422)
        if self.session.scalar(
            select(DriveGrant).where(
                DriveGrant.item_id == item_id,
                DriveGrant.user_id == actor.user_id,
                DriveGrant.revoked_at.is_(None),
            )
        ):
            fail("FILE_GRANT_CONFLICT")
        grant = DriveGrant(
            grant_id=uid(),
            item_id=item_id,
            user_id=actor.user_id,
            role=p["role"],
            expires_at=expiry,
            created_by_user_id=self.user.user_id,
        )
        self.session.add(grant)
        state.acl_revision += 1
        self.audit(item, "grant_add")
        self.session.flush()
        return {
            "grant": self.grant_json(grant, item_id),
            "acl_revision": state.acl_revision,
        }

    def grant_target(self, item, grant_id):
        g = self.session.get(DriveGrant, grant_id)
        if g is None or g.revoked_at is not None:
            fail("FILE_GRANT_NOT_FOUND", 404)
        if g.item_id != item.item_id:
            if g.item_id in [i.item_id for i in ancestors(self.session, item)]:
                fail("INHERITED_PERMISSION")
            fail("FILE_GRANT_NOT_FOUND", 404)
        return g

    def update_grant(self, item_id, grant_id, values):
        p = payload(values)
        item, _ = access_item(self.session, self.user, item_id, "manage_sharing", True)
        state = self.acl(item, p)
        g = self.grant_target(item, grant_id)
        merged = {
            "role": p.get("role", g.role),
            "expires_at": p.get("expires_at", g.expires_at),
        }
        g.expires_at = self.validate_grant(merged)
        g.role = merged["role"]
        g.version += 1
        state.acl_revision += 1
        self.audit(item, "grant_update")
        self.session.flush()
        return {
            "grant": self.grant_json(g, item_id),
            "acl_revision": state.acl_revision,
        }

    def revoke_grant(self, item_id, grant_id, values):
        item, _ = access_item(self.session, self.user, item_id, "manage_sharing", True)
        state = self.acl(item, payload(values))
        g = self.grant_target(item, grant_id)
        g.revoked_at = now()
        g.version += 1
        state.acl_revision += 1
        self.audit(item, "grant_revoke")
        self.session.flush()

    def shared_with_me(self, limit=50, cursor=None):
        actor = self.session.scalar(
            select(User)
            .where(User.user_id == self.user.user_id)
            .execution_options(populate_existing=True)
        )
        if actor is None or actor.status != "active":
            fail("FILE_ITEM_NOT_FOUND", 404)
        seeds = (
            select(DriveItem.item_id.label("item_id"))
            .join(DriveGrant, DriveGrant.item_id == DriveItem.item_id)
            .join(Space, Space.space_id == DriveItem.space_id)
            .where(
                DriveGrant.user_id == self.user.user_id,
                DriveGrant.revoked_at.is_(None),
                or_(DriveGrant.expires_at.is_(None), DriveGrant.expires_at > now()),
                DriveItem.status == "active",
                Space.status == "active",
                Space.kind == "personal",
                Space.owner_user_id != self.user.user_id,
            )
            .distinct()
            .cte("shared_seeds")
        )
        chains = (
            select(
                DriveItem.item_id.label("origin_id"),
                DriveItem.item_id.label("ancestor_id"),
                DriveItem.parent_id.label("parent_id"),
                DriveItem.status.label("status"),
                literal(0).label("depth"),
            )
            .where(DriveItem.item_id.in_(select(seeds.c.item_id)))
            .cte("shared_ancestors", recursive=True)
        )
        chains = chains.union_all(
            select(
                chains.c.origin_id,
                DriveItem.item_id,
                DriveItem.parent_id,
                DriveItem.status,
                chains.c.depth + 1,
            )
            .join(chains, DriveItem.item_id == chains.c.parent_id)
            .where(chains.c.depth < 32)
        )
        redundant = select(chains.c.origin_id).where(
            chains.c.depth > 0, chains.c.ancestor_id.in_(select(seeds.c.item_id))
        )
        unavailable = select(chains.c.origin_id).where(chains.c.status != "active")
        query = select(DriveItem).where(
            DriveItem.item_id.in_(select(seeds.c.item_id)),
            DriveItem.item_id.not_in(redundant),
            DriveItem.item_id.not_in(unavailable),
        )
        return self.page_query(query, limit, cursor, ["shared"])

    def subtree(self, item, status="active"):
        rows = [item]
        index = 0
        while index < len(rows):
            children = self.session.scalars(
                select(DriveItem).where(
                    DriveItem.parent_id == rows[index].item_id,
                    DriveItem.status == status,
                )
            ).all()
            rows.extend(children)
            index += 1
            if len({r.item_id for r in rows}) != len(rows):
                fail("FILE_HIERARCHY_INVALID")
        return rows

    def batch_subtree(self, item, batch_id):
        rows = [item]
        index = 0
        while index < len(rows):
            rows.extend(
                self.session.scalars(
                    select(DriveItem).where(
                        DriveItem.parent_id == rows[index].item_id,
                        DriveItem.status == "trashed",
                        DriveItem.trash_batch_id == batch_id,
                    )
                ).all()
            )
            index += 1
            if len({r.item_id for r in rows}) != len(rows):
                fail("FILE_HIERARCHY_INVALID")
        return rows

    def validate_destination(self, item, parent, name, batch=None):
        chain = ancestors(self.session, parent)
        if item.item_id in [r.item_id for r in chain]:
            fail("FILE_HIERARCHY_INVALID")
        self.unique(parent.item_id, normalize(name)[1], item.item_id)
        rows = (
            self.subtree(item, item.status)
            if batch is None
            else self.batch_subtree(item, batch.batch_id)
        )
        depths = {item.item_id: 0}
        for r in rows[1:]:
            depths[r.item_id] = depths[r.parent_id] + 1
        if len(chain) + max(depths.values()) > 32:
            fail("FILE_HIERARCHY_INVALID", 422)

    def preview(self, item, parent, name, kind, batch=None):
        self.validate_destination(item, parent, name, batch)
        state = self.state(item.space_id)
        old_ids = [r.item_id for r in ancestors(self.session, item)[1:]]
        new_ids = [r.item_id for r in ancestors(self.session, parent)]
        direct_ids = [item.item_id]
        if kind == "restore" and batch:
            direct_ids = self.session.scalars(
                select(DriveItem.item_id).where(
                    DriveItem.trash_batch_id == batch.batch_id
                )
            ).all()
        grants = self.session.scalars(
            select(DriveGrant).where(
                DriveGrant.item_id.in_(list(set(old_ids + new_ids + direct_ids))),
                DriveGrant.revoked_at.is_(None),
            )
        ).all()
        active = [g for g in grants if not g.expires_at or utc(g.expires_at) > now()]
        changes = {
            "lost": [
                self.grant_json(g, item.item_id)
                for g in active
                if kind == "move" and g.item_id in old_ids and g.item_id not in new_ids
            ],
            "gained": [
                self.grant_json(g, item.item_id)
                for g in active
                if (g.item_id in new_ids and g.item_id not in old_ids)
                or kind == "restore"
            ],
        }
        expires = now() + timedelta(minutes=5)
        p = {
            "item_id": item.item_id,
            "target_parent_folder_id": parent.item_id,
            "name": name,
            "expected_metadata_version": item.metadata_version,
            "expected_acl_revision": state.acl_revision,
            "target_metadata_version": parent.metadata_version,
            "permission_changes": changes,
            "batch_version": batch.batch_version if batch else None,
        }
        p = jsonable_encoder(p)
        digest = hashlib.sha256(json.dumps(p, sort_keys=True).encode()).hexdigest()
        record = DriveOperationPreview(
            preview_id=uid(),
            actor_user_id=self.user.user_id,
            space_id=item.space_id,
            kind=kind,
            item_id=item.item_id,
            batch_id=batch.batch_id if batch else None,
            preview_hash=digest,
            payload=p,
            expires_at=expires,
        )
        self.session.add(record)
        self.session.flush()
        return dict(
            p, preview_id=record.preview_id, preview_hash=digest, expires_at=expires
        )

    def prepare_move(self, item_id, values):
        p = payload(values)
        item, _ = access_item(self.session, self.user, item_id, "move", True)
        if item.parent_id is None:
            fail("FILE_PERMISSION_DENIED", 403)
        self.expected(item, p)
        parent = self.parent(p["target_parent_folder_id"], item.space_id, "read")
        name = normalize(p.get("name") or item.name)[0]
        return self.preview(item, parent, name, "move")

    def check_preview(self, item, p, kind, batch=None):
        record = self.session.get(DriveOperationPreview, p.get("preview_id"))
        state = self.state(item.space_id)
        if (
            record is None
            or record.actor_user_id != self.user.user_id
            or record.item_id != item.item_id
            or record.kind != kind
            or record.consumed_at
            or utc(record.expires_at) <= now()
            or record.preview_hash != p.get("preview_hash")
        ):
            fail("FILE_OPERATION_PREVIEW_CONFLICT")
        saved = record.payload
        if (
            saved["expected_acl_revision"] != state.acl_revision
            or p.get("expected_acl_revision") != state.acl_revision
            or saved["expected_metadata_version"] != item.metadata_version
            or (
                kind == "move"
                and p.get("expected_metadata_version") != item.metadata_version
            )
            or (
                batch
                and (
                    record.batch_id != batch.batch_id
                    or saved["batch_version"] != batch.batch_version
                )
            )
        ):
            fail("FILE_OPERATION_PREVIEW_CONFLICT")
        parent = self.parent(saved["target_parent_folder_id"], item.space_id, "read")
        if parent.metadata_version != saved["target_metadata_version"]:
            fail("FILE_OPERATION_PREVIEW_CONFLICT")
        self.validate_destination(item, parent, saved["name"], batch)
        record.consumed_at = now()
        return parent, saved["name"], state

    def commit_move(self, item_id, values):
        p = payload(values)
        item, _ = access_item(self.session, self.user, item_id, "move", True)
        if item.parent_id is None:
            fail("FILE_PERMISSION_DENIED", 403)
        parent, name, state = self.check_preview(item, p, "move")
        item.parent_id = parent.item_id
        item.name, item.normalized_name = normalize(name)
        self.touch(item, "move")
        state.acl_revision += 1
        self.session.flush()
        return item_json(item, self.session)

    move_prepare = prepare_move
    move_commit = commit_move

    def trash(self, item_id, values):
        p = payload(values)
        item, _ = access_item(self.session, self.user, item_id, "trash", True)
        if item.parent_id is None:
            fail("FILE_PERMISSION_DENIED", 403)
        self.expected(item, p)
        batch = DriveTrashBatch(
            batch_id=uid(),
            space_id=item.space_id,
            root_item_id=item.item_id,
            original_parent_folder_id=item.parent_id,
            actor_user_id=self.user.user_id,
            retention_until=now() + timedelta(days=30),
        )
        self.session.add(batch)
        for row in self.subtree(item):
            row.status = "trashed"
            row.trash_batch_id = batch.batch_id
            self.touch(row, "trash")
        self.state(item.space_id).acl_revision += 1
        self.session.flush()
        return batch_json(batch)

    def list_trash(self, space_id, limit=50, cursor=None):
        _, role = space_role(self.session, self.user, space_id)
        if role is None:
            fail("SPACE_NOT_FOUND", 404)
        if role not in ("owner", "admin", "editor"):
            fail("SPACE_PERMISSION_DENIED", 403)
        rows = self.session.scalars(
            select(DriveTrashBatch)
            .where(
                DriveTrashBatch.space_id == space_id,
                DriveTrashBatch.status == "trashed",
            )
            .order_by(DriveTrashBatch.trashed_at, DriveTrashBatch.batch_id)
        ).all()
        selected, next_cursor = self.paginate(
            rows,
            limit,
            cursor,
            ["trash", space_id],
            lambda b: (utc(b.trashed_at).isoformat(), b.batch_id),
        )
        return {
            "trash_batches": [batch_json(b) for b in selected],
            "next_cursor": next_cursor,
        }

    def restore_batch(self, batch_id):
        batch = self.session.get(DriveTrashBatch, batch_id)
        if batch is None:
            fail("FILE_TRASH_NOT_FOUND", 404)
        item, _ = access_item(
            self.session,
            self.user,
            batch.root_item_id,
            "restore",
            True,
            allow_trashed=True,
        )
        if batch.status != "trashed":
            fail("FILE_OPERATION_PREVIEW_CONFLICT")
        return batch, item

    def prepare_restore(self, batch_id, values):
        p = payload(values)
        batch, item = self.restore_batch(batch_id)
        parent = self.parent(
            p.get("target_parent_folder_id") or batch.original_parent_folder_id,
            item.space_id,
            "read",
        )
        name = normalize(p.get("name") or item.name)[0]
        return self.preview(item, parent, name, "restore", batch)

    def commit_restore(self, batch_id, values):
        p = payload(values)
        batch, item = self.restore_batch(batch_id)
        parent, name, state = self.check_preview(item, p, "restore", batch)
        item.parent_id = parent.item_id
        item.name, item.normalized_name = normalize(name)
        rows = self.session.scalars(
            select(DriveItem).where(
                DriveItem.trash_batch_id == batch_id, DriveItem.status == "trashed"
            )
        ).all()
        for row in rows:
            row.status = "active"
            row.trash_batch_id = None
            self.touch(row, "restore")
        batch.status = "restored"
        batch.batch_version += 1
        state.acl_revision += 1
        self.session.flush()
        return {"item": item_json(item, self.session), "trash_batch": batch_json(batch)}

    restore_prepare = prepare_restore
    restore_commit = commit_restore


serialize_item = item_json

normalize_name = normalize
