import asyncio
from pathlib import Path

import httpx

from vessel_service.main import create_app
from vessel_service.settings import Settings


def test_marketing_homenote_and_console_use_separate_bundles(tmp_path: Path) -> None:
    console_dist = tmp_path / "console"
    marketing_dist = tmp_path / "marketing"
    (console_dist / "assets").mkdir(parents=True)
    (marketing_dist / "assets").mkdir(parents=True)
    (console_dist / "index.html").write_text('<script src="/console/assets/app.js"></script>')
    (console_dist / "assets" / "app.js").write_text("window.vesselConsole = true;")
    (marketing_dist / "index.html").write_text('<script src="/assets/site.js"></script>')
    (marketing_dist / "assets" / "site.js").write_text("window.memoryOnCloud = true;")
    app = create_app(
        settings=Settings(environment="test"),
        web_dist_path=console_dist,
        marketing_dist_path=marketing_dist,
    )

    async def request(path: str) -> httpx.Response:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            return await client.get(path)

    homepage = asyncio.run(request("/"))
    assert homepage.status_code == 200
    assert "/assets/site.js" in homepage.text
    assert "text/html" in homepage.headers["content-type"]
    marketing_asset = asyncio.run(request("/assets/site.js"))
    assert marketing_asset.status_code == 200
    assert marketing_asset.text == "window.memoryOnCloud = true;"

    for path in ("/console", "/console/", "/register"):
        response = asyncio.run(request(path))
        assert response.status_code == 200
        assert "/console/assets/app.js" in response.text
        assert "text/html" in response.headers["content-type"]
    asset = asyncio.run(request("/console/assets/app.js"))
    assert asset.status_code == 200
    assert "vesselConsole" in asset.text
