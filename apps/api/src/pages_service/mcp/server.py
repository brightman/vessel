"""Minimal stateless Streamable HTTP MCP endpoint for one Page/Run capability."""

import json
from typing import Any

from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import JSONResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from pages_service.auth.router import get_keyring, get_session, get_settings
from pages_service.mcp.capabilities import CapabilityError, PageCapabilityService
from pages_service.models import Page, PageCapability, PageProposal
from pages_service.proposals.operations import OperationError
from pages_service.proposals.service import ProposalError, ProposalService
from pages_service.settings import Settings

router = APIRouter(tags=["private-pages-mcp"])

TOOLS = [
    {
        "name": "read_current_page",
        "description": "Read the Page bound to this Run capability.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "read_current_selection",
        "description": "Read the selection snapshot explicitly bound to this Run, if any.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "begin_page_edit",
        "description": "Begin or resume a non-authoritative proposal for the current Page.",
        "inputSchema": {
            "type": "object",
            "properties": {"base_revision": {"type": "integer", "minimum": 1}},
            "required": ["base_revision"],
            "additionalProperties": False,
        },
    },
    {
        "name": "append_page_operations",
        "description": (
            "Append complete Page Edit Operations to this Run's proposal. Use only the exact "
            "operation types in the schema; every operation needs a unique operation_id. "
            "Required fields by type: set_title(title); replace_block(block_id, block), with "
            "block.attrs.block_id equal to block_id; replace_range(block_id, expected_text, "
            "replacement); insert_blocks_after(after_block_id, blocks); "
            "delete_blocks(block_ids); move_block(block_id, after_block_id); "
            "replace_document(document), only when the user explicitly requests a full rewrite. "
            "Use null for after_block_id to insert at the start or move to the start. "
            "Example: {\"operation_id\":\"add-intro\",\"type\":\"insert_blocks_after\","
            "\"after_block_id\":null,\"blocks\":[{\"type\":\"paragraph\","
            "\"attrs\":{\"block_id\":\"block-intro\"},\"content\":["
            "{\"type\":\"text\",\"text\":\"Introduction\"}]}]}. "
            "If an operation returns INVALID_OPERATION, correct the reported contract error; "
            "do not retry the same invalid operation."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "proposal_id": {"type": "string"},
                "operations": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "operation_id": {
                                "type": "string",
                                "minLength": 1,
                                "description": "Unique stable ID for this operation; required on every operation.",
                            },
                            "type": {
                                "type": "string",
                                "enum": [
                                    "set_title",
                                    "replace_block",
                                    "replace_range",
                                    "insert_blocks_after",
                                    "delete_blocks",
                                    "move_block",
                                    "replace_document",
                                ],
                                "description": "Use one exact value from this enum. Do not invent aliases such as insert_after or insert_block.",
                            },
                            "title": {
                                "type": "string",
                                "description": "Required by set_title.",
                            },
                            "block_id": {
                                "type": "string",
                                "description": "Required by replace_block, replace_range, and move_block; use a stable block_id from read_current_page.",
                            },
                            "block": {
                                "type": "object",
                                "description": "Required by replace_block. The replacement block must preserve attrs.block_id equal to block_id.",
                            },
                            "expected_text": {
                                "type": "string",
                                "description": "Required by replace_range; exact, unique source text from the target block.",
                            },
                            "replacement": {
                                "type": "string",
                                "description": "Required by replace_range; replacement text.",
                            },
                            "after_block_id": {
                                "type": ["string", "null"],
                                "description": "Required by insert_blocks_after and move_block. Use a stable block_id or null to target the start of the Page.",
                            },
                            "blocks": {
                                "type": "array",
                                "items": {"type": "object"},
                                "description": "Required by insert_blocks_after; complete valid Page blocks, each with a new stable attrs.block_id.",
                            },
                            "block_ids": {
                                "type": "array",
                                "items": {"type": "string"},
                                "description": "Required by delete_blocks; stable block_id values from read_current_page.",
                            },
                            "document": {
                                "type": "object",
                                "description": "Required by replace_document; a complete canonical Page document. Use only for an explicitly requested full rewrite.",
                            },
                        },
                        "required": ["operation_id", "type"],
                        "additionalProperties": False,
                    },
                    "maxItems": 100,
                    "description": "Each item must use one supported operation type and its required fields.",
                },
            },
            "required": ["proposal_id", "operations"],
            "additionalProperties": False,
        },
    },
    {
        "name": "finish_page_edit",
        "description": "Validate and mark this Run's proposal ready for the user to review.",
        "inputSchema": {
            "type": "object",
            "properties": {"proposal_id": {"type": "string"}, "summary": {"type": "string", "minLength": 1, "maxLength": 4000}},
            "required": ["proposal_id", "summary"],
            "additionalProperties": False,
        },
    },
]


def _rpc_result(request_id: Any, result: dict[str, Any]) -> JSONResponse:
    return JSONResponse(
        {"jsonrpc": "2.0", "id": request_id, "result": result},
        headers={"MCP-Protocol-Version": "2025-06-18"},
    )


def _rpc_error(request_id: Any, code: int, message: str) -> JSONResponse:
    return JSONResponse(
        {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}},
        headers={"MCP-Protocol-Version": "2025-06-18"},
    )


def _tool_result(request_id: Any, value: Any, *, is_error: bool = False) -> JSONResponse:
    serialized = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return _rpc_result(request_id, {
        "content": [{"type": "text", "text": serialized}],
        "isError": is_error,
    })


def _proposal_for_capability(
    session: Session,
    *,
    proposal_id: str,
    page_id: str,
    run_id: str,
    owner_user_id: str,
) -> PageProposal:
    proposal = session.scalar(
        select(PageProposal).where(
            PageProposal.proposal_id == proposal_id,
            PageProposal.page_id == page_id,
            PageProposal.run_id == run_id,
            PageProposal.owner_user_id == owner_user_id,
        )
    )
    if proposal is None:
        raise ProposalError("PROPOSAL_NOT_FOUND")
    return proposal


@router.post("/mcp")
async def handle_mcp(
    request: Request,
    session: Session = Depends(get_session),
    keyring=Depends(get_keyring),
    settings: Settings = Depends(get_settings),
) -> Response:
    authorization = request.headers.get("authorization", "")
    token = authorization[7:].strip() if authorization.lower().startswith("bearer ") else ""
    if not token:
        return JSONResponse({"detail": {"code": "PAGE_CAPABILITY_DENIED"}}, status_code=401)
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"detail": {"code": "MCP_INVALID_JSON"}}, status_code=400)
    if not isinstance(body, dict) or body.get("jsonrpc") != "2.0" or not isinstance(body.get("method"), str):
        return _rpc_error(body.get("id") if isinstance(body, dict) else None, -32600, "Invalid JSON-RPC request")
    request_id = body.get("id")
    method = body["method"]
    params = body.get("params") if isinstance(body.get("params"), dict) else {}
    name = ((params.get("name") if isinstance(params, dict) else None) or "")
    required_scope = "page:propose" if name in {"begin_page_edit", "append_page_operations", "finish_page_edit"} else "page:read"
    service = PageCapabilityService(
        session,
        keyring,
        issuer=settings.issuer_url,
        max_lifetime_seconds=settings.page_capability_ttl_seconds,
    )
    try:
        claims = service.verify(token, required_scope=required_scope)
    except CapabilityError:
        session.rollback()
        return JSONResponse({"detail": {"code": "PAGE_CAPABILITY_DENIED"}}, status_code=403)

    if method == "initialize":
        return _rpc_result(request_id, {
            "protocolVersion": "2025-06-18",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "baizhi-pages", "version": "0.1.0"},
        })
    if method == "notifications/initialized" or request_id is None:
        return Response(status_code=202)
    if method == "ping":
        return _rpc_result(request_id, {})
    if method == "tools/list":
        return _rpc_result(request_id, {"tools": TOOLS})
    if method != "tools/call":
        return _rpc_error(request_id, -32601, "Method not found")
    if not isinstance(name, str) or name not in {tool["name"] for tool in TOOLS}:
        return _rpc_error(request_id, -32602, "Unknown tool")

    arguments = params.get("arguments", {})
    if not isinstance(arguments, dict):
        return _tool_result(request_id, {"code": "INVALID_TOOL_ARGUMENTS"}, is_error=True)
    page_id = claims["page_id"]
    run_id = claims["run_id"]
    owner_user_id = claims["sub"]
    try:
        if name == "read_current_page":
            page = session.scalar(
                select(Page).where(
                    Page.page_id == page_id,
                    Page.owner_user_id == owner_user_id,
                    Page.status == "active",
                )
            )
            if page is None:
                raise ProposalError("PAGE_NOT_FOUND")
            return _tool_result(request_id, {
                "page_id": page.page_id,
                "title": page.title,
                "revision": page.revision,
                "markdown": page.markdown,
                "document": page.document_json,
            })

        if name == "read_current_selection":
            capability = session.scalar(select(PageCapability).where(PageCapability.jti == claims["jti"]))
            return _tool_result(request_id, capability.selection_json if capability and capability.selection_json else {"selected": False})

        if name == "begin_page_edit":
            revision = arguments.get("base_revision")
            if isinstance(revision, bool) or not isinstance(revision, int) or revision < 1:
                return _tool_result(request_id, {"code": "INVALID_BASE_REVISION"}, is_error=True)
            proposal = ProposalService(session).begin(
                page_id=page_id,
                owner_user_id=owner_user_id,
                run_id=run_id,
                base_revision=revision,
            )
            session.commit()
            return _tool_result(request_id, {"proposal_id": proposal.proposal_id, "base_revision": proposal.base_revision, "status": proposal.status})

        proposal_id = arguments.get("proposal_id")
        if not isinstance(proposal_id, str) or not proposal_id:
            return _tool_result(request_id, {"code": "INVALID_PROPOSAL_ID"}, is_error=True)
        _proposal_for_capability(
            session,
            proposal_id=proposal_id,
            page_id=page_id,
            run_id=run_id,
            owner_user_id=owner_user_id,
        )
        if name == "append_page_operations":
            operations = arguments.get("operations")
            if not isinstance(operations, list):
                return _tool_result(request_id, {"code": "INVALID_OPERATIONS"}, is_error=True)
            proposal = ProposalService(session).append_operations(
                proposal_id=proposal_id,
                owner_user_id=owner_user_id,
                operations=operations,
            )
            session.commit()
            return _tool_result(request_id, {
                "proposal_id": proposal.proposal_id,
                "status": proposal.status,
                "preview_title": proposal.preview_title,
                "preview_markdown": proposal.preview_markdown,
                "operation_count": len(proposal.operations),
            })

        summary = arguments.get("summary")
        if not isinstance(summary, str):
            return _tool_result(request_id, {"code": "INVALID_PROPOSAL_SUMMARY"}, is_error=True)
        proposal = ProposalService(session).finish(
            proposal_id=proposal_id,
            owner_user_id=owner_user_id,
            summary=summary,
        )
        session.commit()
        return _tool_result(request_id, {
            "proposal_id": proposal.proposal_id,
            "status": proposal.status,
            "summary": proposal.summary,
            "base_revision": proposal.base_revision,
        })
    except (ProposalError, OperationError) as error:
        session.rollback()
        code = error.code if isinstance(error, ProposalError) else "PAGE_OPERATION_INVALID"
        return _tool_result(request_id, {"code": code, "message": str(error)}, is_error=True)
