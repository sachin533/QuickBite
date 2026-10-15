"""Shared test environment: fully isolated PostgreSQL + RabbitMQ.

The suite runs against *real* infrastructure (as required by the assignment),
but never against the developer's running stack: a dedicated database
(``quickbite_test``) and a dedicated RabbitMQ vhost (``quickbite_test``) are
provisioned once per test run, so compose workers/dispatchers polling the
default vhost and database can never observe or steal test traffic.

Environment variables are set at conftest import time — *before* any test
module imports ``app`` — because the SQLAlchemy engine and settings are
bound at import time.

Provisioning needs the stack's PostgreSQL + RabbitMQ reachable:
    docker compose up -d postgres rabbitmq
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote, unquote, urlparse, urlunparse

import pytest

BACKEND_DIR = Path(__file__).resolve().parents[1]

TEST_DB_NAME = os.environ.get("QUICKBITE_TEST_DB", "quickbite_test")
TEST_VHOST = os.environ.get("QUICKBITE_TEST_VHOST", "quickbite_test")

_DEFAULT_DB = "postgresql+psycopg://quickbite:quickbite@localhost:5432/quickbite"
_DEFAULT_AMQP = "amqp://guest:guest@localhost:5672/%2F"
BASE_DATABASE_URL = os.environ.get("DATABASE_URL", _DEFAULT_DB)
BASE_AMQP_URL = os.environ.get("AMQP_URL", _DEFAULT_AMQP)


def _with_database(url: str, database: str) -> str:
    parsed = urlparse(url)
    return urlunparse(parsed._replace(path=f"/{database}"))


def _with_vhost(url: str, vhost: str) -> str:
    parsed = urlparse(url)
    return urlunparse(parsed._replace(path=f"/{quote(vhost, safe='')}"))


def _create_database() -> None:
    """Create the test database when it does not exist yet (idempotent)."""
    from sqlalchemy import create_engine, text

    admin_url = _with_database(BASE_DATABASE_URL, "postgres")
    engine = create_engine(admin_url, isolation_level="AUTOCOMMIT")
    try:
        with engine.connect() as conn:
            exists = conn.execute(
                text("SELECT 1 FROM pg_database WHERE datname = :name"),
                {"name": TEST_DB_NAME},
            ).first()
            if exists is None:
                conn.execute(text(f'CREATE DATABASE "{TEST_DB_NAME}"'))
    finally:
        engine.dispose()


def _run(module: str, *args: str) -> None:
    """Run a backend module (alembic/seed) against the test database."""
    completed = subprocess.run(
        [sys.executable, "-m", module, *args],
        cwd=BACKEND_DIR,
        env={**os.environ},
        capture_output=True,
        text=True,
        timeout=180,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"`python -m {module} {' '.join(args)}` failed against the test "
            f"database:\n{completed.stdout}\n{completed.stderr}"
        )


def _create_vhost() -> None:
    """Create the test vhost + permissions via the RabbitMQ management API."""
    import httpx

    parsed = urlparse(BASE_AMQP_URL)
    user = unquote(parsed.username or "guest")
    password = unquote(parsed.password or "guest")
    host = parsed.hostname or "localhost"
    mgmt = f"http://{host}:15672"
    auth = (user, password)
    try:
        with httpx.Client(timeout=10) as client:
            response = client.put(f"{mgmt}/api/vhosts/{TEST_VHOST}", auth=auth)
            if response.status_code >= 400:
                raise RuntimeError(
                    f"management API refused vhost creation: "
                    f"{response.status_code} {response.text}"
                )
            response = client.put(
                f"{mgmt}/api/permissions/{TEST_VHOST}/{user}",
                auth=auth,
                json={"configure": ".*", "write": ".*", "read": ".*"},
            )
            if response.status_code >= 400:
                raise RuntimeError(
                    f"management API refused permissions grant: "
                    f"{response.status_code} {response.text}"
                )
    except httpx.HTTPError as exc:
        raise RuntimeError(
            "RabbitMQ management API is unreachable at "
            f"{mgmt} — start the stack first: docker compose up -d postgres rabbitmq "
            "(image rabbitmq:*-management is required for tests)"
        ) from exc


def prepare_test_environment() -> None:
    """Idempotently provision database + vhost, then bind this process to them."""
    try:
        _create_database()
    except Exception as exc:  # noqa: BLE001 - re-raise with actionable context
        raise RuntimeError(
            "PostgreSQL is unreachable — start the stack first: "
            "docker compose up -d postgres rabbitmq"
        ) from exc
    _create_vhost()

    # Bind this process to the isolated infrastructure *before* the app is
    # imported anywhere (engine + settings are constructed at import time).
    os.environ["DATABASE_URL"] = _with_database(BASE_DATABASE_URL, TEST_DB_NAME)
    os.environ["AMQP_URL"] = _with_vhost(BASE_AMQP_URL, TEST_VHOST)
    # Deterministic worker behaviour for tests (never inherit the shell's).
    os.environ["PAYMENT_MODE"] = "success"
    os.environ["RESTAURANT_MODE"] = "success"
    os.environ["DELIVERY_MODE"] = "success"
    os.environ["NOTIFICATION_MODE"] = "success"
    # Accelerated retries: same mechanism as production (2/10/30s), faster
    # clock — the compose stack exercises the real delays.
    os.environ["RETRY_DELAYS_SECONDS"] = "0.5,1,1.5"
    os.environ["PAYMENT_DELAY_MS"] = "50"
    os.environ["RESTAURANT_DELAY_MS"] = "30"
    os.environ["DELIVERY_DELAY_MS"] = "30"
    os.environ["NOTIFICATION_DELAY_MS"] = "20"

    # Schema + seed data for the isolated database (both idempotent).
    _run("alembic", "upgrade", "head")
    _run("app.seed")


prepare_test_environment()


# --------------------------------------------------------------------------
# shared fixtures
# --------------------------------------------------------------------------

from app.config import get_settings, reset_settings  # noqa: E402
from app.db import SessionLocal  # noqa: E402
from app.domain.enums import (  # noqa: E402
    OutboxState,
    OrderStatus,
)
from app.models import (  # noqa: E402
    DriverAssignment,
    IdempotencyKey,
    Notification,
    Order,
    OrderItem,
    OrderStatusHistory,
    OutboxEvent,
    ProcessedEvent,
    QuarantineRecord,
    RetryJob,
    SimulatedPayment,
)
from sqlalchemy import delete  # noqa: E402

QUEUE_NAMES = (
    "payment.queue",
    "restaurant.queue",
    "delivery.queue",
    "notification.queue",
    "orders.dead-letter.queue",
)


def reset_pipeline_state() -> None:
    """Empty every pipeline table (seeded catalogue data is preserved)."""
    with SessionLocal() as session:
        for model in (
            Notification,
            IdempotencyKey,
            OrderItem,
            OrderStatusHistory,
            OutboxEvent,
            ProcessedEvent,
            RetryJob,
            QuarantineRecord,
            SimulatedPayment,
            DriverAssignment,
            Order,
        ):
            session.execute(delete(model))
        session.commit()


@pytest.fixture()
def clean_pipeline():
    """Per-test: empty pipeline tables and purge every AMQP queue."""
    import asyncio

    import aio_pika

    reset_pipeline_state()

    async def _purge() -> None:
        settings = get_settings()
        connection = await aio_pika.connect_robust(
            settings.amqp_url, timeout=settings.amqp_connect_timeout_s
        )
        try:
            channel = await connection.channel()
            for name in QUEUE_NAMES:
                queue = await channel.declare_queue(
                    name, durable=True, exclusive=False, auto_delete=False
                )
                await queue.purge()
        finally:
            await connection.close()

    asyncio.run(_purge())
    yield
    reset_pipeline_state()


@pytest.fixture()
def payment_mode():
    """Override PAYMENT_MODE for one test, restoring the default after."""
    reset_settings()
    original = os.environ["PAYMENT_MODE"]

    def _set(mode: str) -> None:
        os.environ["PAYMENT_MODE"] = mode
        reset_settings()

    yield _set
    _set(original)
