import asyncio

import httpx

from vessel_service.main import create_app


def fetch(path):
    async def run():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=create_app()), base_url="http://test"
        ) as client:
            return await client.get(path)

    return asyncio.run(run())


def test_scalar_is_primary_docs_using_local_openapi():
    result = fetch("/docs")
    assert result.status_code == 200
    assert "Scalar.createApiReference" in result.text
    assert "/openapi.json" in result.text
    assert "Vessel API" in result.text


def test_swagger_remains_usable_and_docs_routes_are_not_business_operations():
    swagger = fetch("/swagger")
    assert swagger.status_code == 200
    assert "SwaggerUIBundle" in swagger.text
    assert "/swagger/oauth2-redirect" in swagger.text
    assert fetch("/swagger/oauth2-redirect").status_code == 200
    schema = fetch("/openapi.json").json()
    assert "/docs" not in schema["paths"]
    assert "/swagger" not in schema["paths"]
    assert "/v1/auth/login" in schema["paths"]


def test_scalar_respects_reverse_proxy_prefix():
    async def run():
        transport = httpx.ASGITransport(app=create_app(), root_path="/vessel")
        async with httpx.AsyncClient(
            transport=transport, base_url="http://test"
        ) as client:
            return await client.get("/docs")

    result = asyncio.run(run())
    assert result.status_code == 200
    assert "/vessel/openapi.json" in result.text
