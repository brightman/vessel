import asyncio
from collections.abc import Callable
from pathlib import Path
from typing import Any

import httpx
import pytest
from sqlalchemy.orm import sessionmaker

from vessel_service.database import create_database_engine
from vessel_service.main import create_app
from vessel_service.models.base import Base
from vessel_service.settings import Settings
from vessel_service.auth.tokens import KeyRing


@pytest.fixture
def api_factory(tmp_path: Path) -> Callable[..., Callable[..., httpx.Response]]:
    database_path = tmp_path / "pages-test.sqlite3"
    engine = create_database_engine(f"sqlite+pysqlite:///{database_path}")
    Base.metadata.create_all(engine)
    sessions = sessionmaker(bind=engine, expire_on_commit=False)
    test_keyring = KeyRing.for_test("test-key")

    def build(*, allow_registration: bool = True) -> Callable[..., httpx.Response]:
        application = create_app(
            settings=Settings(
                environment="test",
                issuer_url="https://pages.test",
                allow_registration=allow_registration,
                refresh_cookie_secure=False,
            ),
            engine=engine,
            session_factory=sessions,
            keyring=test_keyring,
        )

        def request(method: str, path: str, **kwargs: Any) -> httpx.Response:
            async def send() -> httpx.Response:
                async with httpx.AsyncClient(
                    transport=httpx.ASGITransport(app=application),
                    base_url="https://pages.test",
                ) as client:
                    cookies = kwargs.pop("cookies", None)
                    if cookies:
                        client.cookies.update(cookies)
                    return await client.request(method, path, **kwargs)

            return asyncio.run(send())

        return request

    return build
