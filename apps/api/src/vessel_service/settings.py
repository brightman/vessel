from typing import Literal
from pathlib import Path

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
    max_asset_upload_bytes: int = 5_242_880
    refresh_cookie_secure: bool = True
    signing_keys_file: Path | None = None
    agent_platform_url: str | None = None
    agent_platform_audience: str = "baizhi-agent-platform"
    agent_platform_request_timeout_seconds: float = 15.0

    @model_validator(mode="after")
    def validate_production_configuration(self) -> "Settings":
        if self.environment == "production":
            if not self.database_url:
                raise ValueError("PAGES_DATABASE_URL is required in production")
            if not self.signing_keys_file:
                raise ValueError("PAGES_SIGNING_KEYS_FILE is required in production")
            if not self.refresh_cookie_secure:
                raise ValueError("PAGES_REFRESH_COOKIE_SECURE must be true in production")
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
