from ipaddress import ip_address
from pathlib import Path
import re
from typing import Literal
from urllib.parse import urlsplit

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="NOTES_", extra="ignore")

    environment: Literal["development", "test", "production"] = "development"
    database_url: str | None = None
    issuer_url: str = "http://127.0.0.1:52003"
    allow_registration: bool = False
    registration_email_verification_required: bool = Field(
        default=True, validation_alias="REGISTRATION_EMAIL_VERIFICATION_REQUIRED"
    )
    registration_code_secret: SecretStr | None = Field(
        default=None, validation_alias="REGISTRATION_CODE_SECRET"
    )
    registration_email_daily_limit: int = Field(
        default=300, ge=1, le=300, validation_alias="REGISTRATION_EMAIL_DAILY_LIMIT"
    )
    brevo_api_key: SecretStr | None = Field(default=None, validation_alias="BREVO_API_KEY")
    brevo_sender_email: str = Field(default="", validation_alias="BREVO_SENDER_EMAIL")
    brevo_sender_name: str = Field(default="Karama", validation_alias="BREVO_SENDER_NAME")
    brevo_timeout_seconds: float = Field(
        default=10.0, gt=0, le=30, validation_alias="BREVO_TIMEOUT_SECONDS"
    )
    access_token_ttl_seconds: int = 900
    refresh_token_ttl_seconds: int = 2_592_000
    note_capability_ttl_seconds: int = 86_400
    asset_storage_path: Path = Path("var/notes-assets")
    app_release_storage_path: Path = Path("var/app-releases")
    app_release_origin: str | None = None
    h5_preview_secret: str | None = None
    max_asset_upload_bytes: int = 5_242_880
    refresh_cookie_secure: bool = True
    signing_keys_file: Path | None = None
    agent_platform_url: str | None = None
    agent_id: str | None = None
    agent_gateway_secret: SecretStr | None = None
    agent_gateway_user_id: str | None = None
    agent_platform_audience: str = "baizhi-agent-platform"
    agent_platform_request_timeout_seconds: float = 15.0

    @field_validator("brevo_sender_email")
    @classmethod
    def validate_sender(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized and not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", normalized):
            raise ValueError("Invalid Brevo sender email")
        return normalized

    @field_validator("registration_code_secret")
    @classmethod
    def validate_code_secret(cls, value: SecretStr | None) -> SecretStr | None:
        if value is not None and len(value.get_secret_value()) < 32:
            raise ValueError("Registration code secret must have at least 32 characters")
        return value

    def app_release_origin_for(self, app_id: str) -> str | None:
        """Return the isolated release origin for one Vessel App."""
        if not self.app_release_origin:
            return None
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", app_id):
            raise ValueError("App ID cannot be used as a release subdomain")
        parsed = urlsplit(self.app_release_origin)
        host = parsed.hostname
        if not host:
            raise ValueError("NOTES_APP_RELEASE_ORIGIN must be an origin URL")
        return f"{parsed.scheme}://{app_id}.{host}{f':{parsed.port}' if parsed.port else ''}"

    @model_validator(mode="after")
    def validate_production_configuration(self) -> "Settings":
        if self.agent_id is not None and not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", self.agent_id):
            raise ValueError("NOTES_AGENT_ID must be one opaque Agent ID")
        if self.agent_platform_url:
            parsed_agent = urlsplit(self.agent_platform_url)
            if parsed_agent.scheme not in {"http", "https"} or not parsed_agent.netloc or parsed_agent.path not in {"", "/"} or parsed_agent.query or parsed_agent.fragment or parsed_agent.username or parsed_agent.password:
                raise ValueError("NOTES_AGENT_PLATFORM_URL must be an origin URL")
            if self.environment == "production" and parsed_agent.scheme != "https":
                raise ValueError("NOTES_AGENT_PLATFORM_URL must use https in production")
        if self.agent_gateway_user_id is not None and not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", self.agent_gateway_user_id):
            raise ValueError("NOTES_AGENT_GATEWAY_USER_ID must be one Agent Platform user ID")
        release_origin = None
        if self.app_release_origin:
            parsed = urlsplit(self.app_release_origin)
            try:
                port = parsed.port
            except ValueError as error:
                raise ValueError("NOTES_APP_RELEASE_ORIGIN must be an origin URL") from error
            if (
                parsed.scheme not in {"http", "https"}
                or not parsed.hostname
                or parsed.path not in {"", "/"}
                or parsed.query
                or parsed.fragment
                or parsed.username
                or parsed.password
            ):
                raise ValueError("NOTES_APP_RELEASE_ORIGIN must be an origin URL")
            try:
                ip_address(parsed.hostname)
            except ValueError:
                pass
            else:
                raise ValueError("NOTES_APP_RELEASE_ORIGIN must use a DNS hostname for App subdomains")
            host = parsed.hostname.lower()
            if ":" in host:
                host = f"[{host}]"
            if port is not None and (parsed.scheme, port) not in {("http", 80), ("https", 443)}:
                host = f"{host}:{port}"
            release_origin = f"{parsed.scheme}://{host}"
            issuer_host = urlsplit(self.issuer_url).hostname
            if parsed.hostname == issuer_host:
                raise ValueError("NOTES_APP_RELEASE_ORIGIN must use a host distinct from NOTES_ISSUER_URL")
            self.app_release_origin = release_origin
        if self.environment == "production":
            if self.allow_registration and not self.registration_email_verification_required:
                raise ValueError("Production self-registration requires email verification")
            if not self.database_url:
                raise ValueError("NOTES_DATABASE_URL is required in production")
            if not self.signing_keys_file:
                raise ValueError("NOTES_SIGNING_KEYS_FILE is required in production")
            if not self.refresh_cookie_secure:
                raise ValueError("NOTES_REFRESH_COOKIE_SECURE must be true in production")
            if not self.h5_preview_secret:
                raise ValueError("NOTES_H5_PREVIEW_SECRET is required in production")
            if not release_origin:
                raise ValueError("NOTES_APP_RELEASE_ORIGIN is required in production")
            if not release_origin.startswith("https://"):
                raise ValueError("NOTES_APP_RELEASE_ORIGIN must use https in production")
        if (
            self.access_token_ttl_seconds < 60
            or self.refresh_token_ttl_seconds < 300
            or not 60 <= self.note_capability_ttl_seconds <= 86_400
        ):
            raise ValueError("Token lifetimes are outside the supported range")
        if not 1_024 <= self.max_asset_upload_bytes <= 26_214_400:
            raise ValueError("Asset upload limit must be between 1 KiB and 25 MiB")
        if self.agent_platform_request_timeout_seconds <= 0:
            raise ValueError("Agent Platform request timeout must be positive")
        return self
