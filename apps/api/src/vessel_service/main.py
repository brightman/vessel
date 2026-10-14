from collections.abc import Callable

from fastapi import FastAPI, HTTPException
from sqlalchemy import Engine, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from vessel_service.auth.tokens import KeyRing
from vessel_service.database import create_database_engine
from vessel_service.settings import Settings


def create_app(
    settings: Settings | None = None,
    engine: Engine | None = None,
    engine_factory: Callable[[str], Engine] = create_database_engine,
    session_factory: sessionmaker[Session] | None = None,
    keyring: KeyRing | None = None,
) -> FastAPI:
    configured = settings or Settings()
    database_engine = engine
    if database_engine is None and configured.database_url:
        database_engine = engine_factory(configured.database_url)
    database_sessions = session_factory
    if database_sessions is None and database_engine is not None:
        database_sessions = sessionmaker(bind=database_engine, expire_on_commit=False)
    active_keyring = keyring
    if active_keyring is None and configured.signing_keys_file:
        active_keyring = KeyRing.from_file(configured.signing_keys_file)
    if active_keyring is None and configured.environment in {"development", "test"}:
        active_keyring = KeyRing.for_development()

    application = FastAPI(title="Vessel API")
    application.state.settings = configured
    application.state.database_engine = database_engine
    application.state.session_factory = database_sessions
    application.state.keyring = active_keyring
    if configured.environment == "production":
        application.state.asset_storage = None
    else:
        from vessel_service.assets.storage import LocalAssetStorage

        application.state.asset_storage = LocalAssetStorage(configured.asset_storage_path)

    @application.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @application.get("/readyz")
    async def readyz() -> dict[str, str]:
        if database_engine is None:
            raise HTTPException(
                status_code=503,
                detail={"code": "DATABASE_NOT_CONFIGURED"},
            )
        try:
            with database_engine.connect() as connection:
                connection.execute(text("SELECT 1"))
        except SQLAlchemyError as error:
            raise HTTPException(
                status_code=503,
                detail={"code": "DATABASE_UNAVAILABLE"},
            ) from error
        return {"status": "ready"}

    from vessel_service.auth.router import router as auth_router
    from vessel_service.assets.router import router as assets_router
    from vessel_service.agent_events import router as agent_events_router
    from vessel_service.agent_platform import router as agent_platform_router
    from vessel_service.directories.router import router as directories_router
    from vessel_service.mcp.server import router as mcp_router
    from vessel_service.pages.router import router as pages_router
    from vessel_service.proposals.router import router as proposals_router
    from vessel_service.spaces.router import router as spaces_router
    from vessel_service.versions.router import router as versions_router

    application.include_router(auth_router)
    application.include_router(assets_router)
    application.include_router(agent_events_router)
    application.include_router(agent_platform_router)
    application.include_router(directories_router)
    application.include_router(pages_router)
    application.include_router(proposals_router)
    application.include_router(spaces_router)
    application.include_router(mcp_router)
    application.include_router(versions_router)
    return application


app = create_app()
