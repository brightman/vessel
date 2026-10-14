"""Authenticated Pages-to-Agent-Platform Run adapter."""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from typing import Any, Literal
from uuid import uuid4

import httpx
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import func, select, update
from sqlalchemy.orm import Session

from pages_service.auth.router import get_keyring, get_session, get_settings
from pages_service.auth.tokens import KeyRing
from pages_service.models import Page, PageCapability, User
from pages_service.mcp.capabilities import CapabilityError, PageCapabilityService
from pages_service.pages.router import _page_or_404, current_user
from pages_service.proposals.service import ProposalService
from pages_service.settings import Settings

router = APIRouter(prefix="/v1/pages/{page_id}/agent", tags=["page-agent-runs"])
PLATFORM_RUN_PATH = "/v1/integrations/pages/runs"
ASSERTION_LIFETIME_SECONDS = 120


class StartAgentRunRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    message: str = Field(min_length=1, max_length=20_000)
    mode: Literal["ask", "edit"] = "ask"
    selection: dict[str, Any] | None = None

    @field_validator("message")
    @classmethod
    def message_must_not_be_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("message must not be blank")
        return value


def _platform_url(settings: Settings, path: str) -> str:
    base = (settings.agent_platform_url or "").strip().rstrip("/")
    if not base.startswith(("https://", "http://")):
        raise HTTPException(status_code=503, detail={"code": "AGENT_PLATFORM_NOT_CONFIGURED"})
    return f"{base}{path}"


def _assertion(user: User, settings: Settings, keyring: KeyRing) -> str:
    return keyring.issue(
        subject=user.user_id,
        issuer=settings.issuer_url,
        audience=settings.agent_platform_audience,
        scope="agent:run",
        lifetime_seconds=ASSERTION_LIFETIME_SECONDS,
    )


def _revoke_run(session: Session, *, page_id: str, run_id: str, status: str) -> None:
    ProposalService(session).terminate_run(page_id=page_id, run_id=run_id, status=status)
    session.execute(
        update(PageCapability)
        .where(PageCapability.page_id == page_id, PageCapability.run_id == run_id, PageCapability.revoked_at.is_(None))
        .values(revoked_at=datetime.now(UTC))
    )
    session.commit()


def _ensure_agent_thread(session: Session, page: Page) -> str:
    """Claim a Page's persistent Agent thread without overwriting a concurrent claim."""
    candidate = f"thread_pages_{uuid4().hex}"
    result = session.execute(
        update(Page)
        .where(Page.page_id == page.page_id, Page.owner_user_id == page.owner_user_id)
        .values(agent_thread_id=func.coalesce(Page.agent_thread_id, candidate))
        .execution_options(synchronize_session=False)
    )
    if result.rowcount != 1:
        session.rollback()
        raise HTTPException(status_code=404, detail={"code": "PAGE_NOT_FOUND"})
    session.commit()
    session.refresh(page)
    if not page.agent_thread_id:
        raise HTTPException(status_code=500, detail={"code": "PAGE_AGENT_THREAD_UNAVAILABLE"})
    return page.agent_thread_id


def _capability_for_owner(
    session: Session, *, page_id: str, run_id: str, owner_user_id: str
) -> PageCapability:
    capability = session.scalar(
        select(PageCapability).where(
            PageCapability.page_id == page_id,
            PageCapability.run_id == run_id,
            PageCapability.owner_user_id == owner_user_id,
        ).order_by(PageCapability.created_at.desc())
    )
    if capability is None:
        raise HTTPException(status_code=404, detail={"code": "AGENT_RUN_NOT_FOUND"})
    return capability


@router.get("/status")
def agent_platform_status(settings: Settings = Depends(get_settings)) -> dict[str, bool]:
    return {"configured": bool((settings.agent_platform_url or "").strip())}


@router.post("/runs", status_code=202)
def start_agent_run(
    page_id: str,
    payload: StartAgentRunRequest,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    keyring: KeyRing = Depends(get_keyring),
) -> dict[str, str]:
    page = _page_or_404(session, user.user_id, page_id)
    if not settings.agent_platform_url:
        raise HTTPException(status_code=503, detail={"code": "AGENT_PLATFORM_NOT_CONFIGURED"})
    url = _platform_url(settings, PLATFORM_RUN_PATH)

    run_id = f"run_pages_{uuid4().hex}"
    thread_id = _ensure_agent_thread(session, page)
    now = datetime.now(UTC)
    run_expires_at = now + timedelta(seconds=settings.page_capability_ttl_seconds)
    capability_service = PageCapabilityService(
        session,
        keyring,
        issuer=settings.issuer_url,
        max_lifetime_seconds=settings.page_capability_ttl_seconds,
    )
    try:
        grant = capability_service.issue(
            owner_user_id=user.user_id,
            page_id=page_id,
            run_id=run_id,
            scopes=["page:read"] if payload.mode == "ask" else ["page:read", "page:propose"],
            run_expires_at=run_expires_at,
            selection=payload.selection,
            now=now,
        )
    except CapabilityError as error:
        session.rollback()
        raise HTTPException(status_code=404, detail={"code": "PAGE_NOT_FOUND"}) from error
    session.commit()

    try:
        response = httpx.post(
            url,
            headers={
                "Authorization": f"Bearer {_assertion(user, settings, keyring)}",
                "X-Pages-Run-Capability": grant.token,
            },
            json={
                "page_id": page_id,
                "run_id": run_id,
                "thread_id": thread_id,
                "message": payload.message,
                "mode": payload.mode,
            },
            timeout=settings.agent_platform_request_timeout_seconds,
        )
        response.raise_for_status()
        platform_run = response.json()
        if platform_run.get("run_id") != run_id or platform_run.get("thread_id") != thread_id:
            raise ValueError("Agent Platform returned an unexpected Run identity")
    except (httpx.HTTPError, ValueError, TypeError) as error:
        _revoke_run(session, page_id=page_id, run_id=run_id, status="failed")
        raise HTTPException(status_code=502, detail={"code": "AGENT_PLATFORM_RUN_START_FAILED"}) from error

    return {"page_id": page_id, "thread_id": thread_id, "run_id": run_id, "status": str(platform_run.get("status") or "queued")}


@router.get("/runs/{run_id}/events")
async def stream_agent_run_events(
    page_id: str,
    run_id: str,
    request: Request,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    keyring: KeyRing = Depends(get_keyring),
    last_event_id: str | None = Header(default=None, alias="Last-Event-ID"),
) -> StreamingResponse:
    _page_or_404(session, user.user_id, page_id)
    _capability_for_owner(session, page_id=page_id, run_id=run_id, owner_user_id=user.user_id)
    url = _platform_url(settings, f"{PLATFORM_RUN_PATH}/{run_id}/events")
    headers = {"Authorization": f"Bearer {_assertion(user, settings, keyring)}", "Accept": "text/event-stream"}
    if last_event_id:
        headers["Last-Event-ID"] = last_event_id

    client = httpx.AsyncClient(timeout=None)
    try:
        upstream_request = client.build_request("GET", url, headers=headers)
        upstream = await client.send(upstream_request, stream=True)
        if upstream.is_error:
            await upstream.aclose()
            await client.aclose()
            raise HTTPException(status_code=502, detail={"code": "AGENT_PLATFORM_EVENTS_UNAVAILABLE"})
    except httpx.HTTPError as error:
        await client.aclose()
        raise HTTPException(status_code=502, detail={"code": "AGENT_PLATFORM_EVENTS_UNAVAILABLE"}) from error

    async def stream() -> AsyncIterator[bytes]:
        event_name = ""
        data_lines: list[str] = []
        terminal = False
        terminal_status: str | None = None
        try:
            async for line in upstream.aiter_lines():
                if line.startswith("event:"):
                    event_name = line[6:].strip()
                elif line.startswith("data:"):
                    data_lines.append(line[5:].lstrip())
                elif line == "":
                    if event_name == "done" and data_lines:
                        try:
                            status = json.loads("\n".join(data_lines)).get("status")
                            terminal = status in {
                                "completed", "failed", "cancelled", "timeout",
                                "awaiting_input", "interrupted_max_rounds",
                                "interrupted_context_budget", "interrupted_model_timeout",
                            }
                            if terminal:
                                terminal_status = status
                        except (json.JSONDecodeError, AttributeError):
                            pass
                    event_name = ""
                    data_lines.clear()
                yield (line + "\n").encode("utf-8")
                if terminal:
                    break
            if terminal:
                with request.app.state.session_factory() as final_session:
                    _revoke_run(final_session, page_id=page_id, run_id=run_id, status=terminal_status or "failed")
        finally:
            await upstream.aclose()
            await client.aclose()

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-store, no-transform", "X-Accel-Buffering": "no"},
    )


@router.post("/runs/{run_id}/cancel")
def cancel_agent_run(
    page_id: str,
    run_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    keyring: KeyRing = Depends(get_keyring),
) -> dict[str, str]:
    _page_or_404(session, user.user_id, page_id)
    _capability_for_owner(session, page_id=page_id, run_id=run_id, owner_user_id=user.user_id)
    url = _platform_url(settings, f"{PLATFORM_RUN_PATH}/{run_id}/cancel")
    try:
        response = httpx.post(
            url,
            headers={"Authorization": f"Bearer {_assertion(user, settings, keyring)}"},
            timeout=settings.agent_platform_request_timeout_seconds,
        )
        response.raise_for_status()
    except httpx.HTTPError as error:
        raise HTTPException(status_code=502, detail={"code": "AGENT_PLATFORM_CANCEL_FAILED"}) from error
    _revoke_run(session, page_id=page_id, run_id=run_id, status="cancelled")
    return {"run_id": run_id, "status": "cancelled"}
