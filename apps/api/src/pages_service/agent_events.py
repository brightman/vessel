"""Authenticated replay endpoint for durable, redacted Page Agent events."""

from __future__ import annotations

import asyncio
import json
import time
from collections.abc import AsyncIterator

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request
from fastapi.responses import StreamingResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from pages_service.auth.router import get_session
from pages_service.models import PageAgentEvent, User
from pages_service.pages.router import _page_or_404, current_user

router = APIRouter(prefix="/v1/pages/{page_id}/agent", tags=["page-agent-events"])


def _sse(event: PageAgentEvent) -> str:
    envelope = {
        "event_id": event.event_id,
        "correlation_id": event.correlation_id,
        "page_id": event.page_id,
        "proposal_id": event.proposal_id,
        "run_id": event.run_id,
        "occurred_at": event.created_at.isoformat(),
        "payload": event.payload,
    }
    return f"id: {event.event_id}\nevent: {event.event_type}\ndata: {json.dumps(envelope, separators=(',', ':'), ensure_ascii=False)}\n\n"


@router.get("/events")
def replay_page_agent_events(
    page_id: str,
    request: Request,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
    last_event_id: str | None = Header(default=None, alias="Last-Event-ID"),
    wait_seconds: float = Query(default=25, ge=0, le=30),
) -> StreamingResponse:
    _page_or_404(session, user.user_id, page_id)
    after_sequence = 0
    if last_event_id:
        cursor = session.scalar(
            select(PageAgentEvent).where(
                PageAgentEvent.event_id == last_event_id,
                PageAgentEvent.page_id == page_id,
            )
        )
        if cursor is None:
            raise HTTPException(status_code=400, detail={"code": "INVALID_EVENT_CURSOR"})
        after_sequence = cursor.sequence_id

    session_factory = request.app.state.session_factory
    if session_factory is None:
        raise HTTPException(status_code=503, detail={"code": "DATABASE_NOT_CONFIGURED"})
    session.close()

    async def stream() -> AsyncIterator[str]:
        sequence = after_sequence
        deadline = time.monotonic() + wait_seconds
        next_heartbeat = time.monotonic() + 10
        yield "retry: 1000\n\n"
        first_poll = True
        while first_poll or time.monotonic() < deadline:
            first_poll = False
            if await request.is_disconnected():
                return
            with session_factory() as polling_session:
                events = list(polling_session.scalars(
                    select(PageAgentEvent)
                    .where(
                        PageAgentEvent.page_id == page_id,
                        PageAgentEvent.sequence_id > sequence,
                    )
                    .order_by(PageAgentEvent.sequence_id)
                    .limit(100)
                ).all())
            if events:
                for event in events:
                    sequence = event.sequence_id
                    yield _sse(event)
                if wait_seconds == 0 or time.monotonic() >= deadline:
                    return
                continue
            if wait_seconds == 0:
                return
            now = time.monotonic()
            if now >= next_heartbeat:
                yield ": keep-alive\n\n"
                next_heartbeat = now + 10
            await asyncio.sleep(min(1, max(0, deadline - now)))

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache, no-transform",
            "X-Accel-Buffering": "no",
        },
    )
