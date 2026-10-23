"""Authenticated replay endpoint for durable, redacted Note Agent events."""

from __future__ import annotations

import asyncio
import json
import time
from collections.abc import AsyncIterator

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request
from fastapi.responses import StreamingResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from vessel_service.auth.router import get_session
from vessel_service.models import NoteAgentEvent, User
from vessel_service.notes.router import current_user
from vessel_service.spaces.resources import note_for_user

router = APIRouter(prefix="/v1/notes/{note_id}/agent", tags=["note-agent-events"])


def _sse(event: NoteAgentEvent) -> str:
    envelope = {
        "event_id": event.event_id,
        "correlation_id": event.correlation_id,
        "note_id": event.note_id,
        "proposal_id": event.proposal_id,
        "run_id": event.run_id,
        "occurred_at": event.created_at.isoformat(),
        "payload": event.payload,
    }
    return f"id: {event.event_id}\nevent: {event.event_type}\ndata: {json.dumps(envelope, separators=(',', ':'), ensure_ascii=False)}\n\n"


@router.get("/events")
def replay_note_agent_events(
    note_id: str,
    request: Request,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
    last_event_id: str | None = Header(default=None, alias="Last-Event-ID"),
    wait_seconds: float = Query(default=25, ge=0, le=30),
) -> StreamingResponse:
    note_for_user(session, user, note_id)
    after_sequence = 0
    if last_event_id:
        cursor = session.scalar(
            select(NoteAgentEvent).where(
                NoteAgentEvent.event_id == last_event_id,
                NoteAgentEvent.note_id == note_id,
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
                actor = polling_session.get(User, user.user_id)
                if actor is None:
                    return
                try:
                    note_for_user(polling_session, actor, note_id)
                except HTTPException:
                    return
                events = list(polling_session.scalars(
                    select(NoteAgentEvent)
                    .where(
                        NoteAgentEvent.note_id == note_id,
                        NoteAgentEvent.sequence_id > sequence,
                    )
                    .order_by(NoteAgentEvent.sequence_id)
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
