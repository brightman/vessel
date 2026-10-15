from datetime import UTC, datetime

from fastapi import HTTPException
from sqlalchemy import literal, or_, select

from vessel_service.models import Space, TeamMember, User

from .models import DriveGrant, DriveItem


def fail(code, status=409):
    raise HTTPException(status_code=status, detail={"code": code})


def utc(dt):
    return dt.replace(tzinfo=UTC) if dt.tzinfo is None else dt


def space_role(session, user, space_id, lock=False):
    if user is None:
        fail("SPACE_NOT_FOUND", 404)
    actor = session.scalar(
        select(User)
        .where(User.user_id == user.user_id)
        .execution_options(populate_existing=True)
    )
    space = session.scalar(
        select(Space).where(Space.space_id == space_id).with_for_update()
        if lock
        else select(Space).where(Space.space_id == space_id)
    )
    if (
        actor is None
        or actor.status != "active"
        or space is None
        or space.status != "active"
    ):
        fail("SPACE_NOT_FOUND", 404)
    session.refresh(space)
    if space.kind == "personal":
        role = "owner" if space.owner_user_id == user.user_id else None
    else:
        member = session.scalar(
            select(TeamMember)
            .where(TeamMember.space_id == space_id, TeamMember.user_id == user.user_id)
            .execution_options(populate_existing=True)
        )
        role = member.role if member and member.status == "active" else None
    return space, role


def ancestors(session, item):
    rows = []
    seen = set()
    while item is not None:
        if item.item_id in seen or len(rows) > 32:
            fail("FILE_HIERARCHY_INVALID")
        seen.add(item.item_id)
        rows.append(item)
        item = (
            session.scalar(
                select(DriveItem)
                .where(DriveItem.item_id == item.parent_id)
                .execution_options(populate_existing=True)
            )
            if item.parent_id
            else None
        )
    return rows


def effective(session, user, item, space, role):
    sources = []
    if role:
        sources = [{"type": "space_role", "role": role, "source_item_id": item.item_id}]
    if space.kind == "personal" and role is None:
        chain = ancestors(session, item)
        # A trashed ancestor makes every descendant unavailable, even with a direct grant.
        if any(row.status != "active" for row in chain):
            return None, []
        grants = session.scalars(
            select(DriveGrant).where(
                DriveGrant.item_id.in_([r.item_id for r in chain]),
                DriveGrant.user_id == user.user_id,
                DriveGrant.revoked_at.is_(None),
            )
        ).all()
        for g in grants:
            if g.expires_at is None or utc(g.expires_at) > datetime.now(UTC):
                sources.append(
                    {
                        "type": "grant",
                        "grant_id": g.grant_id,
                        "role": g.role,
                        "source_item_id": g.item_id,
                    }
                )
        if sources:
            role = "editor" if any(s["role"] == "editor" for s in sources) else "viewer"
    return role, sources


def access_item(session, user, item_id, action="read", lock=False, allow_trashed=False):
    item = session.scalar(
        select(DriveItem)
        .where(DriveItem.item_id == item_id)
        .execution_options(populate_existing=True)
    )
    if item is None:
        fail("FILE_ITEM_NOT_FOUND", 404)
    try:
        space, role = space_role(session, user, item.space_id, lock)
    except HTTPException:
        fail("FILE_ITEM_NOT_FOUND", 404)
    if lock:
        session.refresh(item)
    if item.status != "active" and not (allow_trashed and item.status == "trashed"):
        fail("FILE_ITEM_NOT_FOUND", 404)
    role, sources = effective(session, user, item, space, role)
    if role is None:
        fail("FILE_ITEM_NOT_FOUND", 404)
    writer = role in ("owner", "admin", "editor")
    structure = (space.kind == "team" and writer) or role == "owner"
    caps = {
        "item_id": item.item_id,
        "can_read": True,
        "can_write": writer,
        "can_create_children": writer and item.kind == "folder",
        "can_move": structure,
        "can_trash": structure,
        "can_restore": structure,
        "can_manage_sharing": space.kind == "personal" and role == "owner",
        "can_purge": role in ("owner", "admin"),
        "permission_sources": sources,
    }
    if not caps.get("can_" + action, False):
        fail("FILE_PERMISSION_DENIED", 403)
    return item, caps


def visible_items_query(session, user, space_id):
    """SQL visibility scope: seed valid grants, recurse active descendants <=32."""
    space, role = space_role(session, user, space_id)
    base = select(DriveItem).where(
        DriveItem.space_id == space_id, DriveItem.status == "active"
    )
    if role is not None:
        return base
    if space.kind != "personal":
        return base.where(False)
    seeds = (
        select(DriveItem.item_id.label("item_id"), literal(0).label("depth"))
        .join(DriveGrant, DriveGrant.item_id == DriveItem.item_id)
        .where(
            DriveItem.space_id == space_id,
            DriveItem.status == "active",
            DriveGrant.user_id == user.user_id,
            DriveGrant.revoked_at.is_(None),
            or_(
                DriveGrant.expires_at.is_(None),
                DriveGrant.expires_at > datetime.now(UTC),
            ),
        )
        .cte("visible_file_items", recursive=True)
    )
    visible = seeds.union_all(
        select(DriveItem.item_id, seeds.c.depth + 1)
        .join(seeds, DriveItem.parent_id == seeds.c.item_id)
        .where(
            DriveItem.space_id == space_id,
            DriveItem.status == "active",
            seeds.c.depth < 32,
        )
    )
    return base.where(DriveItem.item_id.in_(select(visible.c.item_id)))
