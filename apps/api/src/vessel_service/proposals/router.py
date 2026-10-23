from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from vessel_service.auth.router import get_session
from vessel_service.models import Note, NoteProposal, User
from vessel_service.notes.router import current_user, serialize_note
from vessel_service.spaces.resources import note_for_user
from vessel_service.proposals.service import ProposalError, ProposalService

router = APIRouter(prefix="/v1/notes/{note_id}/proposals", tags=["note-proposals"])


class AcceptProposalRequest(BaseModel):
    idempotency_key: str = Field(min_length=1, max_length=128)


def _proposal_or_404(session: Session, note_id: str, proposal_id: str, owner_user_id: str) -> NoteProposal:
    proposal = session.scalar(
        select(NoteProposal).where(
            NoteProposal.proposal_id == proposal_id,
            NoteProposal.note_id == note_id,
            NoteProposal.owner_user_id == owner_user_id,
        )
    )
    if proposal is None:
        raise HTTPException(status_code=404, detail={"code": "PROPOSAL_NOT_FOUND"})
    return proposal


def serialize_proposal(proposal: NoteProposal) -> dict[str, object]:
    return {
        "proposal_id": proposal.proposal_id,
        "note_id": proposal.note_id,
        "base_revision": proposal.base_revision,
        "run_id": proposal.run_id,
        "status": proposal.status,
        "summary": proposal.summary,
        "preview": {
            "title": proposal.preview_title,
            "document": proposal.preview_document,
            "markdown": proposal.preview_markdown,
        },
        "operation_count": len(proposal.operations),
        "failure_code": proposal.failure_code,
        "created_at": proposal.created_at.isoformat(),
        "updated_at": proposal.updated_at.isoformat(),
    }


@router.get("")
def list_active_proposals(
    note_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, list[dict[str, object]]]:
    note_for_user(session, user, note_id)
    proposals = session.scalars(
        select(NoteProposal)
        .join(Note, Note.note_id == NoteProposal.note_id)
        .where(
            NoteProposal.note_id == note_id,
            NoteProposal.owner_user_id == user.user_id,
            NoteProposal.status.in_(["streaming", "ready"]),
            Note.revision == NoteProposal.base_revision,
        )
        .order_by(NoteProposal.updated_at.desc())
        .limit(10)
    ).all()
    return {"proposals": [serialize_proposal(proposal) for proposal in proposals]}


def _raise_service_error(session: Session, error: ProposalError) -> None:
    if error.code == "NOTE_REVISION_CONFLICT":
        # Preserve the explicit superseded state set by the service on stale CAS.
        session.commit()
        raise HTTPException(status_code=409, detail={"code": error.code}) from error
    session.rollback()
    if error.code in {"NOTE_NOT_FOUND", "PROPOSAL_NOT_FOUND"}:
        status_code = 404
    elif error.code == "SPACE_PERMISSION_DENIED":
        status_code = 403
    elif error.code.startswith("INVALID_"):
        status_code = 422
    else:
        status_code = 409
    raise HTTPException(status_code=status_code, detail={"code": error.code, "message": str(error)}) from error


@router.get("/{proposal_id}")
def get_proposal(
    note_id: str,
    proposal_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, object]:
    note_for_user(session, user, note_id)
    return serialize_proposal(_proposal_or_404(session, note_id, proposal_id, user.user_id))


@router.post("/{proposal_id}/accept")
def accept_proposal(
    note_id: str,
    proposal_id: str,
    payload: AcceptProposalRequest,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, object]:
    note_for_user(session, user, note_id, write=True)
    proposal = _proposal_or_404(session, note_id, proposal_id, user.user_id)
    try:
        note = ProposalService(session).accept(
            proposal_id=proposal.proposal_id,
            owner_user_id=user.user_id,
            idempotency_key=payload.idempotency_key,
        )
        session.commit()
    except ProposalError as error:
        _raise_service_error(session, error)
    return {"note": serialize_note(note)}


@router.post("/{proposal_id}/reject")
def reject_proposal(
    note_id: str,
    proposal_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, object]:
    note_for_user(session, user, note_id, write=True)
    _proposal_or_404(session, note_id, proposal_id, user.user_id)
    try:
        proposal = ProposalService(session).reject(
            proposal_id=proposal_id,
            owner_user_id=user.user_id,
        )
        session.commit()
    except ProposalError as error:
        _raise_service_error(session, error)
    return {"proposal": serialize_proposal(proposal)}
