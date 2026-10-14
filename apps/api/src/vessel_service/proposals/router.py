from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from vessel_service.auth.router import get_session
from vessel_service.models import Page, PageProposal, User
from vessel_service.pages.router import _page_or_404, current_user, serialize_page
from vessel_service.proposals.service import ProposalError, ProposalService

router = APIRouter(prefix="/v1/pages/{page_id}/proposals", tags=["page-proposals"])


class AcceptProposalRequest(BaseModel):
    idempotency_key: str = Field(min_length=1, max_length=128)


def _proposal_or_404(session: Session, page_id: str, proposal_id: str, owner_user_id: str) -> PageProposal:
    proposal = session.scalar(
        select(PageProposal).where(
            PageProposal.proposal_id == proposal_id,
            PageProposal.page_id == page_id,
            PageProposal.owner_user_id == owner_user_id,
        )
    )
    if proposal is None:
        raise HTTPException(status_code=404, detail={"code": "PROPOSAL_NOT_FOUND"})
    return proposal


def serialize_proposal(proposal: PageProposal) -> dict[str, object]:
    return {
        "proposal_id": proposal.proposal_id,
        "page_id": proposal.page_id,
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
    page_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, list[dict[str, object]]]:
    _page_or_404(session, user.user_id, page_id)
    proposals = session.scalars(
        select(PageProposal)
        .join(Page, Page.page_id == PageProposal.page_id)
        .where(
            PageProposal.page_id == page_id,
            PageProposal.owner_user_id == user.user_id,
            PageProposal.status.in_(["streaming", "ready"]),
            Page.revision == PageProposal.base_revision,
        )
        .order_by(PageProposal.updated_at.desc())
        .limit(10)
    ).all()
    return {"proposals": [serialize_proposal(proposal) for proposal in proposals]}


def _raise_service_error(session: Session, error: ProposalError) -> None:
    if error.code == "PAGE_REVISION_CONFLICT":
        # Preserve the explicit superseded state set by the service on stale CAS.
        session.commit()
        raise HTTPException(status_code=409, detail={"code": error.code}) from error
    session.rollback()
    if error.code in {"PAGE_NOT_FOUND", "PROPOSAL_NOT_FOUND"}:
        status_code = 404
    elif error.code.startswith("INVALID_"):
        status_code = 422
    else:
        status_code = 409
    raise HTTPException(status_code=status_code, detail={"code": error.code, "message": str(error)}) from error


@router.get("/{proposal_id}")
def get_proposal(
    page_id: str,
    proposal_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, object]:
    return serialize_proposal(_proposal_or_404(session, page_id, proposal_id, user.user_id))


@router.post("/{proposal_id}/accept")
def accept_proposal(
    page_id: str,
    proposal_id: str,
    payload: AcceptProposalRequest,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, object]:
    proposal = _proposal_or_404(session, page_id, proposal_id, user.user_id)
    try:
        page = ProposalService(session).accept(
            proposal_id=proposal.proposal_id,
            owner_user_id=user.user_id,
            idempotency_key=payload.idempotency_key,
        )
        session.commit()
    except ProposalError as error:
        _raise_service_error(session, error)
    return {"page": serialize_page(page)}


@router.post("/{proposal_id}/reject")
def reject_proposal(
    page_id: str,
    proposal_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict[str, object]:
    _proposal_or_404(session, page_id, proposal_id, user.user_id)
    try:
        proposal = ProposalService(session).reject(
            proposal_id=proposal_id,
            owner_user_id=user.user_id,
        )
        session.commit()
    except ProposalError as error:
        _raise_service_error(session, error)
    return {"proposal": serialize_proposal(proposal)}
