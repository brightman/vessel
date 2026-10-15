from ipaddress import ip_address
from pathlib import Path
import re
from typing import Literal
from urllib.parse import urlsplit

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="PAGES_", extra="ignore")

    environment: Literal["development", "test", "production"] = "development"
    database_url: str | None = None
    issuer_url: str = "http://127.0.0.1:52003"
    allow_registration: bool = False
    access_token_ttl_seconds: int = 900
    refresh_token_ttl_seconds: int = 2_592_000
    page_capability_ttl_seconds: int = 86_400
    asset_storage_path: Path = Path("var/pages-assets")
    app_release_storage_path: Path = Path("var/app-releases")
    app_release_origin: str | None = None
    h5_preview_secret: str | None = None
    max_asset_upload_bytes: int = 5_242_880
    refresh_cookie_secure: bool = True
    signing_keys_file: Path | None = None
    agent_platform_url: str | None = None
    agent_platform_audience: str = "baizhi-agent-platform"
    agent_platform_request_timeout_seconds: float = 15.0

    def app_release_origin_for(self, app_id: str) -> str | None:
        """Return the isolated release origin for one Vessel App."""
        if not self.app_release_origin:
            return None
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", app_id):
            raise ValueError("App ID cannot be used as a release subdomain")
        parsed = urlsplit(self.app_release_origin)
        host = parsed.hostname
        if not host:
            raise ValueError("PAGES_APP_RELEASE_ORIGIN must be an origin URL")
        return f"{parsed.scheme}://{app_id}.{host}{f':{parsed.port}' if parsed.port else ''}"

    @model_validator(mode="after")
    def validate_production_configuration(self) -> "Settings":
        release_origin = None
        if self.app_release_origin:
            parsed = urlsplit(self.app_release_origin)
            try:
                port = parsed.port
            except ValueError as error:
                raise ValueError("PAGES_APP_RELEASE_ORIGIN must be an origin URL") from error
            if (
                parsed.scheme not in {"http", "https"}
                or not parsed.hostname
                or parsed.path not in {"", "/"}
                or parsed.query
                or parsed.fragment
                or parsed.username
                or parsed.password
            ):
                raise ValueError("PAGES_APP_RELEASE_ORIGIN must be an origin URL")
            try:
                ip_address(parsed.hostname)
            except ValueError:
                pass
            else:
                raise ValueError("PAGES_APP_RELEASE_ORIGIN must use a DNS hostname for App subdomains")
            host = parsed.hostname.lower()
            if ":" in host:
                host = f"[{host}]"
            if port is not None and (parsed.scheme, port) not in {("http", 80), ("https", 443)}:
                host = f"{host}:{port}"
            release_origin = f"{parsed.scheme}://{host}"
            issuer_host = urlsplit(self.issuer_url).hostname
            if parsed.hostname == issuer_host:
                raise ValueError("PAGES_APP_RELEASE_ORIGIN must use a host distinct from PAGES_ISSUER_URL")
            self.app_release_origin = release_origin
        if self.environment == "production":
            if not self.database_url:
                raise ValueError("PAGES_DATABASE_URL is required in production")
            if not self.signing_keys_file:
                raise ValueError("PAGES_SIGNING_KEYS_FILE is required in production")
            if not self.refresh_cookie_secure:
                raise ValueError("PAGES_REFRESH_COOKIE_SECURE must be true in production")
            if not self.h5_preview_secret:
                raise ValueError("PAGES_H5_PREVIEW_SECRET is required in production")
            if not release_origin:
                raise ValueError("PAGES_APP_RELEASE_ORIGIN is required in production")
            if not release_origin.startswith("https://"):
                raise ValueError("PAGES_APP_RELEASE_ORIGIN must use https in production")
        if (
            self.access_token_ttl_seconds < 60
            or self.refresh_token_ttl_seconds < 300
            or not 60 <= self.page_capability_ttl_seconds <= 86_400
        ):
            raise ValueError("Token lifetimes are outside the supported range")
        if not 1_024 <= self.max_asset_upload_bytes <= 26_214_400:
            raise ValueError("Asset upload limit must be between 1 KiB and 25 MiB")
        if self.agent_platform_request_timeout_seconds <= 0:
            raise ValueError("Agent Platform request timeout must be positive")
        return self
