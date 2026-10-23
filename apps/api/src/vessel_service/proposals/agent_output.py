"""Turn an untrusted Agent reply into a Vessel-owned Note proposal."""

from __future__ import annotations

import json
from typing import Any
from uuid import uuid4

from sqlalchemy.orm import Session

from vessel_service.proposals.service import ProposalError, ProposalService


_OPERATION_FIELDS = {
    "set_title": {"title"},
    "replace_block": {"block_id", "block_json"},
    "replace_range": {"block_id", "expected_text", "replacement"},
    "insert_blocks_after": {"after_block_id", "blocks_json"},
    "delete_blocks": {"block_ids"},
    "move_block": {"block_id", "after_block_id"},
}


def parse_agent_proposal(output_text: object, *, base_revision: int) -> tuple[list[dict[str, Any]], str]:
    if not isinstance(output_text, str) or not output_text.strip() or len(output_text.encode("utf-8")) > 2_000_000:
        raise ProposalError("INVALID_AGENT_PROPOSAL_JSON")
    try:
        value = json.loads(output_text)
    except (json.JSONDecodeError, ValueError) as error:
        raise ProposalError("INVALID_AGENT_PROPOSAL_JSON") from error
    if not isinstance(value, dict) or set(value) != {"base_revision", "operations", "summary"}:
        raise ProposalError("INVALID_AGENT_PROPOSAL_SCHEMA")
    if type(value["base_revision"]) is not int or value["base_revision"] != base_revision:
        raise ProposalError("NOTE_REVISION_CONFLICT")
    operations = value["operations"]
    if not isinstance(operations, list) or not 1 <= len(operations) <= 100:
        raise ProposalError("INVALID_AGENT_PROPOSAL_SCHEMA")
    summary = value["summary"]
    if not isinstance(summary, str) or not summary.strip() or len(summary) > 4_000:
        raise ProposalError("INVALID_AGENT_PROPOSAL_SCHEMA")
    normalized: list[dict[str, Any]] = []
    for operation in operations:
        if not isinstance(operation, dict) or not isinstance(operation.get("type"), str):
            raise ProposalError("INVALID_AGENT_PROPOSAL_SCHEMA")
        fields = _OPERATION_FIELDS.get(operation["type"])
        if fields is None or set(operation) != {"type", *fields}:
            raise ProposalError("INVALID_AGENT_PROPOSAL_SCHEMA")
        canonical = dict(operation)
        if operation["type"] in {"replace_block", "insert_blocks_after"}:
            source_key = "block_json" if operation["type"] == "replace_block" else "blocks_json"
            target_key = "block" if operation["type"] == "replace_block" else "blocks"
            if not isinstance(canonical[source_key], str) or len(canonical[source_key]) > 1_000_000:
                raise ProposalError("INVALID_AGENT_PROPOSAL_SCHEMA")
            try:
                canonical[target_key] = json.loads(canonical.pop(source_key))
            except (json.JSONDecodeError, ValueError) as error:
                raise ProposalError("INVALID_AGENT_PROPOSAL_JSON") from error
        normalized.append({**canonical, "operation_id": str(uuid4())})
    return normalized, summary.strip()


def save_agent_proposal(
    session: Session, *, note_id: str, owner_user_id: str, run_id: str,
    base_revision: int, output_text: object,
) -> None:
    operations, summary = parse_agent_proposal(output_text, base_revision=base_revision)
    service = ProposalService(session)
    proposal = service.begin(
        note_id=note_id, owner_user_id=owner_user_id, run_id=run_id,
        base_revision=base_revision,
    )
    service.append_operations(
        proposal_id=proposal.proposal_id, owner_user_id=owner_user_id,
        operations=operations,
    )
    service.finish(
        proposal_id=proposal.proposal_id, owner_user_id=owner_user_id,
        summary=summary,
    )
