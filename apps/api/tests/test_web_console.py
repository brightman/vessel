import asyncio
from pathlib import Path

import httpx

from vessel_service.main import create_app
from vessel_service.settings import Settings


def test_console_and_registration_share_built_frontend(tmp_path: Path) -> None:
    (tmp_path / "assets").mkdir()
    (tmp_path / "index.html").write_text('<script src="/console/assets/app.js"></script>')
    (tmp_path / "assets" / "app.js").write_text("window.vesselConsole = true;")
    app = create_app(settings=Settings(environment="test"), web_dist_path=tmp_path)

    async def request(path: str) -> httpx.Response:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            return await client.get(path)

    for path in ("/console", "/console/", "/register"):
        response = asyncio.run(request(path))
        assert response.status_code == 200
        assert "/console/assets/app.js" in response.text
        assert "text/html" in response.headers["content-type"]
    asset = asyncio.run(request("/console/assets/app.js"))
    assert asset.status_code == 200
    assert "vesselConsole" in asset.text
