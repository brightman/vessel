from uuid import uuid4

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from vessel_service.models import Space, TeamMember, User


ROLE_CAPABILITIES = {
    "owner": {"can_read": True, "can_write": True, "can_manage_members": True, "can_delete": True},
    "admin": {"can_read": True, "can_write": True, "can_manage_members": True, "can_delete": True},
    "editor": {"can_read": True, "can_write": True, "can_manage_members": False, "can_delete": False},
    "viewer": {"can_read": True, "can_write": False, "can_manage_members": False, "can_delete": False},
}


def create_personal_space(session: Session, user: User) -> Space:
    space = Space(
        space_id=str(uuid4()), kind="personal", name=f"{user.name[:108]} Personal",
        owner_user_id=user.user_id, created_by_user_id=user.user_id, status="active",
    )
    session.add(space)
    return space


def space_access(
    session: Session, user: User, space_id: str, *, capability: str = "can_read", lock: bool = False
) -> tuple[Space, str]:
    query = select(Space).where(Space.space_id == space_id, Space.status == "active")
    if lock:
        query = query.with_for_update()
    space = session.scalar(query)
    if space is None:
        raise HTTPException(status_code=404, detail={"code": "SPACE_NOT_FOUND"})
    if space.kind == "personal":
        role = "owner" if space.owner_user_id == user.user_id else None
    else:
        membership = session.get(TeamMember, (space_id, user.user_id))
        role = membership.role if membership and membership.status == "active" else None
    if role is None:
        raise HTTPException(status_code=404, detail={"code": "SPACE_NOT_FOUND"})
    if not ROLE_CAPABILITIES[role][capability]:
        raise HTTPException(status_code=403, detail={"code": "SPACE_PERMISSION_DENIED"})
    return space, role
