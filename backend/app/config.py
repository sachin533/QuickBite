"""Application configuration.

All settings come from the environment (or a local ``.env`` file that is
never committed). Configuration is validated eagerly at process start so that
a misconfigured service fails fast instead of at the first request.
"""

from __future__ import annotations

from functools import lru_cache
from typing import Literal

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

CORS_SEPARATOR = ","


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # --- service identity -------------------------------------------------
    app_name: str = "QuickBite API"
    environment: Literal["development", "test", "production"] = "development"
    log_level: str = "INFO"

    # --- PostgreSQL -------------------------------------------------------
    # SQLAlchemy dialect URL, e.g. postgresql+psycopg://user:pass@host:5432/db
    database_url: str = "postgresql+psycopg://quickbite:quickbite@localhost:5432/quickbite"
    db_pool_size: int = Field(default=5, ge=1, le=50)
    db_max_overflow: int = Field(default=10, ge=0, le=50)
    db_connect_timeout_s: int = Field(default=5, ge=1, le=60)

    # --- RabbitMQ ---------------------------------------------------------
    amqp_url: str = "amqp://guest:guest@localhost:5672/%2F"
    amqp_connect_timeout_s: float = Field(default=10.0, ge=1.0, le=60.0)
    amqp_publisher_confirms: bool = True
    # Prefetch must stay finite so one worker cannot hoard the queue.
    worker_prefetch: int = Field(default=8, ge=1, le=256)
    # Bounded retry policy: 1 initial attempt + N delayed retries.
    retry_max_attempts: int = Field(default=3, ge=1, le=10)
    retry_delays_seconds: str = "2,10,30"

    # --- authentication ---------------------------------------------------
    jwt_secret: str = Field(default="", min_length=0)
    jwt_algorithm: str = "HS256"
    jwt_expires_minutes: int = Field(default=60, ge=5, le=1440)

    # --- HTTP / CORS ------------------------------------------------------
    # Explicit origins only; never "*" together with credentialed requests.
    cors_origins: str = "http://localhost:5173,http://localhost:3000"

    # --- simulation controls (development / test only) --------------------
    payment_delay_ms: int = Field(default=150, ge=0, le=60_000)
    restaurant_delay_ms: int = Field(default=100, ge=0, le=60_000)
    delivery_delay_ms: int = Field(default=100, ge=0, le=60_000)
    notification_delay_ms: int = Field(default=50, ge=0, le=60_000)
    # success | fail_twice | fail_always  (deterministic demo controls)
    payment_mode: Literal["success", "fail_twice", "fail_always"] = "success"
    restaurant_mode: Literal["success", "fail_always"] = "success"
    delivery_mode: Literal["success", "fail_always"] = "success"
    notification_mode: Literal["success", "fail_always"] = "success"

    # --- pagination -------------------------------------------------------
    default_page_size: int = Field(default=20, ge=1, le=100)
    max_page_size: int = Field(default=100, ge=1, le=100)

    # --- business limits (documented checkout validation) -----------------
    max_distinct_items: int = Field(default=20, ge=1, le=100)
    max_quantity_per_item: int = Field(default=20, ge=1, le=100)
    min_delivery_address_chars: int = Field(default=8, ge=1, le=200)

    # ---------------------------------------------------------------------
    @field_validator("jwt_secret")
    @classmethod
    def _strip_secret(cls, value: str) -> str:
        return value.strip()

    @field_validator("retry_delays_seconds")
    @classmethod
    def _validate_delays(cls, value: str) -> str:
        parts = [p.strip() for p in value.split(",") if p.strip()]
        if not parts:
            raise ValueError("retry_delays_seconds must contain at least one delay")
        for part in parts:
            delay = float(part)
            if delay < 0:
                raise ValueError("retry delays must be >= 0")
        return ",".join(str(float(p)) for p in parts)

    @model_validator(mode="after")
    def _validate_required_secrets(self) -> "Settings":
        # Production must never boot with a default or short secret.
        if len(self.jwt_secret) < 32:
            raise ValueError(
                "JWT_SECRET must be set to a random string of at least 32 characters "
                "(see .env.example)"
            )
        if self.environment == "production":
            if self.cors_origins.strip() in {"*", ""}:
                raise ValueError("CORS_ORIGINS must list explicit origins in production")
            if "guest:guest" in self.amqp_url:
                raise ValueError("AMQP_URL still uses the default guest credentials")
        return self

    # --- derived helpers --------------------------------------------------
    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(CORS_SEPARATOR) if o.strip()]

    @property
    def retry_delay_list(self) -> list[float]:
        return [float(p) for p in self.retry_delays_seconds.split(",")]

    @property
    def is_production(self) -> bool:
        return self.environment == "production"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Cached settings instance. Call :func:`reset_settings` in tests."""
    return Settings()


def reset_settings() -> None:
    """Drop the cached settings (used when tests mutate the environment)."""
    get_settings.cache_clear()


def load_settings_or_fail() -> Settings:
    """Entry point used by the API, workers, and scripts.

    Raises a readable error when validation fails so containers exit during
    startup instead of serving broken traffic.
    """
    return get_settings()
