import asyncio
import logging
from collections.abc import Callable
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy import Engine, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from vessel_service.api_docs import API_TAGS, add_api_docs
from vessel_service.auth.tokens import KeyRing
from vessel_service.database import create_database_engine
from vessel_service.settings import Settings


logger = logging.getLogger(__name__)


def create_app(
    settings: Settings | None = None,
    engine: Engine | None = None,
    engine_factory: Callable[[str], Engine] = create_database_engine,
    session_factory: sessionmaker[Session] | None = None,
    keyring: KeyRing | None = None,
    testing_legacy_notes_agent: bool = False,
    web_dist_path: Path | None = None,
    marketing_dist_path: Path | None = None,
) -> FastAPI:
    configured = settings or Settings()
    if testing_legacy_notes_agent and configured.environment != "test":
        raise ValueError("Legacy Notes Agent routes are test-only")
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

    application = FastAPI(
        title="Karama.Cloud API",
        description="Personal and team storage for files, Notes and structured Apps.",
        docs_url="/swagger",
        openapi_tags=API_TAGS,
        swagger_ui_oauth2_redirect_url="/swagger/oauth2-redirect",
    )

    @application.middleware("http")
    async def h5_record_cors(request: Request, call_next):
        """Permit an App release to call only its typed-record endpoints.

        App HTML runs on the isolated release origin.  It needs to send its
        short-lived App token to the API, while the broader Vessel API must
        never become cross-origin readable by that untrusted HTML.
        """
        origin = request.headers.get("origin")
        path = request.url.path.strip("/").split("/")
        is_record_endpoint = (
            len(path) >= 6
            and path[:2] == ["v1", "apps"]
            and path[3:4] == ["tables"]
            and path[5:6] == ["records"]
        )
        app_id = path[2] if is_record_endpoint else None
        try:
            allowed_origin = configured.app_release_origin_for(app_id) if app_id else None
        except ValueError:
            allowed_origin = None
        if not allowed_origin or not is_record_endpoint or origin != allowed_origin:
            return await call_next(request)

        if request.method == "OPTIONS":
            requested_method = request.headers.get("access-control-request-method", "").upper()
            requested_headers = {
                header.strip().lower()
                for header in request.headers.get("access-control-request-headers", "").split(",")
                if header.strip()
            }
            if requested_method not in {"GET", "POST", "PATCH", "DELETE"} or not requested_headers <= {
                "authorization", "content-type"
            }:
                return Response(status_code=403, headers={"Vary": "Origin"})
            return Response(
                status_code=204,
                headers={
                    "Access-Control-Allow-Origin": allowed_origin,
                    "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE",
                    "Access-Control-Allow-Headers": "Authorization, Content-Type",
                    "Access-Control-Max-Age": "600",
                    "Vary": "Origin",
                },
            )

        response = await call_next(request)
        response.headers["Access-Control-Allow-Origin"] = allowed_origin
        response.headers["Vary"] = "Origin"
        return response

    add_api_docs(application)
    web_dist = web_dist_path or Path(__file__).resolve().parents[4] / "dist" / "console"
    marketing_dist = marketing_dist_path or Path(__file__).resolve().parents[4] / "dist" / "marketing"

    @application.get("/", include_in_schema=False)
    def marketing_home() -> FileResponse:
        index = marketing_dist / "index.html"
        if not index.is_file():
            raise HTTPException(status_code=503, detail={"code": "MARKETING_SITE_NOT_BUILT"})
        return FileResponse(index, media_type="text/html", headers={"Cache-Control": "no-store"})

    @application.get("/console", include_in_schema=False)
    @application.get("/console/", include_in_schema=False)
    @application.get("/register", include_in_schema=False)
    def web_console() -> FileResponse:
        index = web_dist / "index.html"
        if not index.is_file():
            raise HTTPException(status_code=503, detail={"code": "WEB_CONSOLE_NOT_BUILT"})
        return FileResponse(index, media_type="text/html", headers={"Cache-Control": "no-store"})

    application.mount("/console/assets", StaticFiles(directory=web_dist / "assets", check_dir=False), name="console-assets")
    application.mount("/assets", StaticFiles(directory=marketing_dist / "assets", check_dir=False), name="marketing-assets")
    from vessel_service.auth.email_verification import BrevoMailer
    application.state.registration_mailer = BrevoMailer(configured)
    application.state.settings = configured
    application.state.database_engine = database_engine
    application.state.session_factory = database_sessions
    application.state.keyring = active_keyring
    if database_sessions is not None and configured.environment != "test":
        from vessel_service.agent_platform import reconcile_pending_runs

        async def reconcile_agent_runs() -> None:
            while True:
                try:
                    await asyncio.to_thread(reconcile_pending_runs, database_sessions, configured)
                except Exception:
                    logger.exception("Note Agent Run reconciliation failed")
                await asyncio.sleep(5)

        @application.on_event("startup")
        async def start_agent_reconciler() -> None:
            application.state.agent_reconciler = asyncio.create_task(reconcile_agent_runs())

        @application.on_event("shutdown")
        async def stop_agent_reconciler() -> None:
            task = application.state.agent_reconciler
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
    from vessel_service.files.storage import FilesSettings, OSSStorage

    file_settings = FilesSettings()
    application.state.file_settings = file_settings
    application.state.file_storage = (
        OSSStorage(file_settings)
        if file_settings.oss_final_bucket or file_settings.oss_config_file
        else None
    )
    from vessel_service.apps.release_storage import LocalAppReleaseStorage, OSSAppReleaseStorage

    application.state.app_release_storage = (
        OSSAppReleaseStorage(file_settings)
        if file_settings.oss_final_bucket or file_settings.oss_config_file
        else (None if configured.environment == "production" else LocalAppReleaseStorage(configured.app_release_storage_path))
    )
    if configured.environment == "production":
        application.state.asset_storage = None
    else:
        from vessel_service.assets.storage import LocalAssetStorage

        application.state.asset_storage = LocalAssetStorage(configured.asset_storage_path)

    @application.get("/healthz", tags=["system"])
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @application.get("/readyz", tags=["system"])
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
    from vessel_service.apps.router import router as apps_router
    from vessel_service.assets.router import router as assets_router
    from vessel_service.directories.router import router as directories_router, space_router as space_directories_router
    from vessel_service.notes.router import router as notes_router
    from vessel_service.notes.space_router import router as space_notes_router
    from vessel_service.spaces.router import router as spaces_router
    from vessel_service.versions.router import router as versions_router

    from vessel_service.files.router import router as files_router

    application.include_router(files_router)
    application.include_router(auth_router, tags=["auth"])
    application.include_router(apps_router)
    application.include_router(assets_router)
    application.include_router(directories_router)
    application.include_router(space_directories_router)
    application.include_router(notes_router)
    application.include_router(space_notes_router)
    application.include_router(spaces_router)
    application.include_router(versions_router)
    from vessel_service.agent_events import router as agent_events_router
    from vessel_service.agent_platform import router as agent_platform_router
    from vessel_service.mcp.server import router as mcp_router
    from vessel_service.proposals.router import router as proposals_router

    application.include_router(agent_events_router)
    application.include_router(agent_platform_router)
    application.include_router(mcp_router)
    application.include_router(proposals_router)
    return application


app = create_app()
