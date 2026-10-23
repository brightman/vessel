import asyncio

import httpx

from vessel_service.main import app, create_app
from vessel_service.settings import Settings


async def _get_health() -> httpx.Response:
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://notes.test"
    ) as client:
        return await client.get("/healthz")


async def _get_ready(application) -> httpx.Response:
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=application), base_url="http://notes.test"
    ) as client:
        return await client.get("/readyz")


def test_health_endpoint_returns_ok_status() -> None:
    response = asyncio.run(_get_health())

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
    assert app.title == "Karama.Cloud API"


def test_readiness_endpoint_reports_missing_database_configuration() -> None:
    response = asyncio.run(_get_ready(app))

    assert response.status_code == 503
    assert response.json() == {"detail": {"code": "DATABASE_NOT_CONFIGURED"}}


def test_readiness_endpoint_checks_the_configured_database() -> None:
    application = create_app(Settings(database_url="sqlite+pysqlite:///:memory:"))
    response = asyncio.run(_get_ready(application))

    assert response.status_code == 200
    assert response.json() == {"status": "ready"}
