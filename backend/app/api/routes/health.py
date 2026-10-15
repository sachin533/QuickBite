"""Health probes.

``/health/live``  -> process liveness only (no dependency checks).
``/health/ready`` -> real dependency checks with bounded timeouts; 503 when a
required dependency is unavailable.

Documented readiness semantics
------------------------------
* ``database`` is required: readiness fails without PostgreSQL.
* ``broker`` is reported but *not required* for API readiness: the
  transactional outbox keeps accepted orders safe while RabbitMQ is down, so
  an accepted PENDING order may be waiting for messaging recovery. The API
  stays ready as long as it can persist orders; the broker check surfaces in
  the payload for operators.
"""

from __future__ import annotations

import asyncio

import aio_pika
from fastapi import APIRouter
from fastapi.responses import JSONResponse

from app.api.errors import envelope
from app.config import get_settings
from app.db import check_database

router = APIRouter(tags=["health"])


async def _check_broker(timeout_s: float) -> tuple[bool, str]:
    settings = get_settings()
    try:
        # Short-lived plain connection: a probe must not start reconnect loops.
        connection = await aio_pika.connect(settings.amqp_url, timeout=timeout_s)
        await connection.close()
        return True, "reachable"
    except Exception as exc:  # pragma: no cover - depends on broker state
        return False, type(exc).__name__


@router.get("/health/live", summary="Process liveness probe")
def live() -> dict[str, str]:
    return {"status": "alive"}


@router.get("/health/ready", summary="Dependency readiness probe")
async def ready() -> JSONResponse:
    settings = get_settings()
    # Bounded waits: never let a probe hang on a dead dependency.
    db_ok = await asyncio.to_thread(check_database, settings.db_connect_timeout_s)
    broker_ok, broker_detail = await _check_broker(settings.amqp_connect_timeout_s)

    checks = {
        "database": {"ok": db_ok, "required": True},
        "broker": {
            "ok": broker_ok,
            "required": False,
            "detail": broker_detail,
            "note": (
                "Broker downtime does not invalidate a committed order; "
                "accepted PENDING orders wait in the outbox for recovery."
            ),
        },
    }
    if db_ok:
        return JSONResponse(
            status_code=200,
            content={"status": "ready", "checks": checks},
        )
    payload = envelope(None, "not_ready", "PostgreSQL is unavailable", checks)
    return JSONResponse(status_code=503, content=payload)
