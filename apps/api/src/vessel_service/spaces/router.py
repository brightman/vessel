from datetime import UTC, datetime, timedelta
from typing import Literal
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from vessel_service.auth.router import get_session
from vessel_service.models import Space, TeamInvitation, TeamMember, User
from vessel_service.notes.router import current_user
from vessel_service.spaces.permissions import ROLE_CAPABILITIES, space_access

router = APIRouter(tags=["spaces"])
Role = Literal["owner", "admin", "editor", "viewer"]


class TeamCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)

    @field_validator("name")
    @classmethod
    def normalized_name(cls, value: str) -> str:
        name = value.strip()
        if not name:
            raise ValueError("Team name cannot be blank")
        return name


class InvitationCreate(BaseModel):
    invitee_user_id: str
    role: Role


class RoleUpdate(BaseModel):
    role: Role


def _space_payload(space: Space, role: str) -> dict[str, str | None]:
    return {
        "space_id": space.space_id,
        "kind": space.kind,
        "name": space.name,
        "owner_user_id": space.owner_user_id,
        "role": role,
        "status": space.status,
    }


def _invitation_payload(invitation: TeamInvitation) -> dict[str, str]:
    return {
        "invitation_id": invitation.invitation_id,
        "space_id": invitation.space_id,
        "invitee_user_id": invitation.invitee_user_id,
        "invited_by_user_id": invitation.invited_by_user_id,
        "role": invitation.role,
        "status": invitation.status,
        "expires_at": invitation.expires_at.isoformat(),
    }


def _as_utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def _team_for_write(session: Session, user: User, space_id: str) -> tuple[Space, str]:
    space, role = space_access(session, user, space_id, capability="can_manage_members", lock=True)
    if space.kind != "team":
        raise HTTPException(status_code=404, detail={"code": "TEAM_NOT_FOUND"})
    return space, role


def _member_or_404(session: Session, space_id: str, user_id: str) -> TeamMember:
    member = session.get(TeamMember, (space_id, user_id))
    if member is None or member.status != "active":
        raise HTTPException(status_code=404, detail={"code": "TEAM_MEMBER_NOT_FOUND"})
    return member


def _protect_last_owner(session: Session, space_id: str, member: TeamMember) -> None:
    target = session.get(User, member.user_id)
    if member.role == "owner" and target and target.status == "active":
        owners = session.scalar(
            select(func.count()).select_from(TeamMember).join(
                User, User.user_id == TeamMember.user_id
            ).where(
                TeamMember.space_id == space_id,
                TeamMember.role == "owner",
                TeamMember.status == "active",
                User.status == "active",
            )
        )
        if owners <= 1:
            raise HTTPException(status_code=409, detail={"code": "LAST_TEAM_OWNER"})


@router.get("/v1/spaces")
def list_spaces(user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    personal = session.scalars(
        select(Space).where(Space.kind == "personal", Space.owner_user_id == user.user_id, Space.status == "active")
    ).all()
    teams = session.execute(
        select(Space, TeamMember.role).join(TeamMember, TeamMember.space_id == Space.space_id).where(
            TeamMember.user_id == user.user_id, TeamMember.status == "active", Space.status == "active"
        )
    ).all()
    return {"spaces": [_space_payload(space, "owner") for space in personal] + [
        _space_payload(space, role) for space, role in teams
    ]}


@router.get("/v1/spaces/{space_id}/permissions")
def get_permissions(space_id: str, user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    space, role = space_access(session, user, space_id)
    return {"space_id": space.space_id, "role": role, **ROLE_CAPABILITIES[role]}


@router.post("/v1/teams", status_code=201)
def create_team(payload: TeamCreate, user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    space = Space(
        space_id=str(uuid4()), kind="team", name=payload.name,
        owner_user_id=None, created_by_user_id=user.user_id, status="active",
    )
    session.add(space)
    session.add(TeamMember(space_id=space.space_id, user_id=user.user_id, role="owner", status="active"))
    session.commit()
    return {"space": _space_payload(space, "owner")}


@router.get("/v1/teams/{space_id}")
def get_team(space_id: str, user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    space, role = space_access(session, user, space_id)
    if space.kind != "team":
        raise HTTPException(status_code=404, detail={"code": "TEAM_NOT_FOUND"})
    return {"space": _space_payload(space, role)}


@router.get("/v1/teams/{space_id}/members")
def list_members(space_id: str, user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    space, _ = space_access(session, user, space_id)
    if space.kind != "team":
        raise HTTPException(status_code=404, detail={"code": "TEAM_NOT_FOUND"})
    members = session.scalars(select(TeamMember).where(
        TeamMember.space_id == space_id, TeamMember.status == "active"
    ).order_by(TeamMember.joined_at, TeamMember.user_id)).all()
    return {"members": [{"user_id": member.user_id, "role": member.role, "status": member.status} for member in members]}


@router.post("/v1/teams/{space_id}/invitations", status_code=201)
def invite_member(
    space_id: str, payload: InvitationCreate,
    user: User = Depends(current_user), session: Session = Depends(get_session),
) -> dict:
    _, role = _team_for_write(session, user, space_id)
    if role != "owner" and payload.role == "owner":
        raise HTTPException(status_code=403, detail={"code": "SPACE_PERMISSION_DENIED"})
    invitee = session.get(User, payload.invitee_user_id)
    if invitee is None or invitee.status != "active":
        raise HTTPException(status_code=404, detail={"code": "USER_NOT_FOUND"})
    existing_member = session.get(TeamMember, (space_id, payload.invitee_user_id))
    if existing_member and existing_member.status == "active":
        raise HTTPException(status_code=409, detail={"code": "ALREADY_TEAM_MEMBER"})
    pending = session.scalar(select(TeamInvitation).where(
        TeamInvitation.space_id == space_id,
        TeamInvitation.invitee_user_id == payload.invitee_user_id,
        TeamInvitation.status == "pending",
    ))
    now = datetime.now(UTC)
    if pending:
        if _as_utc(pending.expires_at) > now:
            raise HTTPException(status_code=409, detail={"code": "INVITATION_ALREADY_PENDING"})
        pending.status = "expired"
        pending.responded_at = now
        session.flush()
    invitation = TeamInvitation(
        invitation_id=str(uuid4()), space_id=space_id,
        invitee_user_id=payload.invitee_user_id, invited_by_user_id=user.user_id,
        role=payload.role, status="pending", expires_at=now + timedelta(days=7),
    )
    session.add(invitation)
    try:
        session.commit()
    except IntegrityError as error:
        session.rollback()
        raise HTTPException(status_code=409, detail={"code": "INVITATION_ALREADY_PENDING"}) from error
    return {"invitation": _invitation_payload(invitation)}


@router.get("/v1/teams/{space_id}/invitations")
def list_team_invitations(
    space_id: str, user: User = Depends(current_user), session: Session = Depends(get_session)
) -> dict:
    space, _ = space_access(session, user, space_id, capability="can_manage_members")
    if space.kind != "team":
        raise HTTPException(status_code=404, detail={"code": "TEAM_NOT_FOUND"})
    invitations = session.scalars(select(TeamInvitation).where(
        TeamInvitation.space_id == space_id,
        TeamInvitation.status == "pending",
        TeamInvitation.expires_at > datetime.now(UTC),
    ).order_by(TeamInvitation.created_at, TeamInvitation.invitation_id)).all()
    return {"invitations": [_invitation_payload(invitation) for invitation in invitations]}


@router.get("/v1/team-invitations")
def list_my_invitations(user: User = Depends(current_user), session: Session = Depends(get_session)) -> dict:
    invitations = session.scalars(select(TeamInvitation).where(
        TeamInvitation.invitee_user_id == user.user_id,
        TeamInvitation.status == "pending", TeamInvitation.expires_at > datetime.now(UTC),
    ).order_by(TeamInvitation.created_at, TeamInvitation.invitation_id)).all()
    return {"invitations": [_invitation_payload(invitation) for invitation in invitations]}


@router.delete("/v1/teams/{space_id}/invitations/{invitation_id}", status_code=204)
def revoke_invitation(
    space_id: str, invitation_id: str,
    user: User = Depends(current_user), session: Session = Depends(get_session),
) -> Response:
    _team_for_write(session, user, space_id)
    invitation = session.scalar(select(TeamInvitation).where(
        TeamInvitation.invitation_id == invitation_id,
        TeamInvitation.space_id == space_id,
        TeamInvitation.status == "pending",
    ))
    if invitation is None:
        raise HTTPException(status_code=404, detail={"code": "INVITATION_NOT_FOUND"})
    invitation.status = "revoked"
    invitation.responded_at = datetime.now(UTC)
    session.commit()
    return Response(status_code=204)


@router.post("/v1/team-invitations/{invitation_id}/accept")
def accept_invitation(
    invitation_id: str, user: User = Depends(current_user), session: Session = Depends(get_session)
) -> dict:
    invitation = session.scalar(select(TeamInvitation).where(
        TeamInvitation.invitation_id == invitation_id,
        TeamInvitation.invitee_user_id == user.user_id,
    ))
    if invitation is None:
        raise HTTPException(status_code=404, detail={"code": "INVITATION_NOT_FOUND"})
    space = session.scalar(select(Space).where(
        Space.space_id == invitation.space_id, Space.kind == "team", Space.status == "active"
    ).with_for_update())
    if space is None:
        raise HTTPException(status_code=404, detail={"code": "INVITATION_NOT_FOUND"})
    session.refresh(invitation)
    if invitation.status != "pending" or _as_utc(invitation.expires_at) <= datetime.now(UTC):
        raise HTTPException(status_code=409, detail={"code": "INVITATION_NOT_ACTIVE"})
    member = session.get(TeamMember, (space.space_id, user.user_id))
    if member and member.status == "active":
        raise HTTPException(status_code=409, detail={"code": "ALREADY_TEAM_MEMBER"})
    if member:
        member.role = invitation.role
        member.status = "active"
        member.joined_at = datetime.now(UTC)
    else:
        session.add(TeamMember(
            space_id=space.space_id, user_id=user.user_id, role=invitation.role, status="active"
        ))
    invitation.status = "accepted"
    invitation.responded_at = datetime.now(UTC)
    session.commit()
    return {"space": _space_payload(space, invitation.role)}


@router.patch("/v1/teams/{space_id}/members/{member_id}")
def change_member_role(
    space_id: str, member_id: str, payload: RoleUpdate,
    user: User = Depends(current_user), session: Session = Depends(get_session),
) -> dict:
    _, actor_role = _team_for_write(session, user, space_id)
    member = _member_or_404(session, space_id, member_id)
    if actor_role != "owner" and (member.role == "owner" or payload.role == "owner"):
        raise HTTPException(status_code=403, detail={"code": "SPACE_PERMISSION_DENIED"})
    if member.role == "owner" and payload.role != "owner":
        _protect_last_owner(session, space_id, member)
    member.role = payload.role
    session.commit()
    return {"member": {"user_id": member.user_id, "role": member.role, "status": member.status}}


@router.delete("/v1/teams/{space_id}/members/{member_id}", status_code=204)
def remove_member(
    space_id: str, member_id: str,
    user: User = Depends(current_user), session: Session = Depends(get_session),
) -> Response:
    _, actor_role = _team_for_write(session, user, space_id)
    member = _member_or_404(session, space_id, member_id)
    if actor_role != "owner" and member.role == "owner":
        raise HTTPException(status_code=403, detail={"code": "SPACE_PERMISSION_DENIED"})
    _protect_last_owner(session, space_id, member)
    member.status = "removed"
    session.commit()
    return Response(status_code=204)
