"""Outbox dispatcher: publishes committed outbox rows with confirms.

Polls ``outbox_events`` for due PENDING rows (``available_at <= now``),
publishes each one by one with publisher confirms + mandatory routing, and
marks it SENT only after an unambiguous confirm. On failure the row stays
PENDING with the error recorded and is retried on the next poll — an
accepted order's events are never lost, and a crash between publish and
commit results in at-least-once delivery (consumers deduplicate via
``processed_events``).

Retry rows (``target_queue`` set) go out through the default exchange with
the ``x-attempt`` header; their ``retry_jobs`` bookkeeping row is marked
PUBLISHED only after the confirmed publish.
"""

from __future__ import annotations

import asyncio
import logging

import aio_pika
from sqlalchemy import select, update
from sqlalchemy.exc import SQLAlchemyError

from app.config import get_settings
from app.db import SessionLocal
from app.domain.enums import OutboxState, RetryJobStatus
from app.messaging.publisher import publish_confirmed
from app.messaging.topology import declare_topology
from app.models import OutboxEvent, RetryJob, utcnow

LOGGER = logging.getLogger("quickbite.outbox")

POLL_INTERVAL_S = 0.2  # idle poll; publishes loop back immediately
BATCH_SIZE = 100


def _due_row_ids() -> list[str]:
    with SessionLocal() as db:
        rows = db.execute(
            select(OutboxEvent.id)
            .where(
                OutboxEvent.state == OutboxState.PENDING.value,
                OutboxEvent.available_at <= utcnow(),
            )
            .order_by(OutboxEvent.available_at, OutboxEvent.id)
            .limit(BATCH_SIZE)
        ).all()
        return [row[0] for row in rows]


async def _publish_row(channel, row_id: str) -> bool:
    """Publish one outbox row under its row lock; True when marked SENT."""
    db = SessionLocal()
    try:
        # skip_locked: a concurrent dispatcher already owns this row; it will
        # be re-polled if it ends up still PENDING.
        row = db.execute(
            select(OutboxEvent)
            .where(OutboxEvent.id == row_id)
            .with_for_update(skip_locked=True)
        ).scalar_one_or_none()
        if (
            row is None
            or row.state != OutboxState.PENDING.value
            or row.available_at > utcnow()
        ):
            db.rollback()
            return False

        headers = {"x-attempt": row.retry_attempt} if row.retry_attempt else None
        exchange_name = "" if row.target_queue else row.exchange
        routing_key = row.target_queue or row.routing_key
        try:
            await publish_confirmed(
                channel,
                exchange_name=exchange_name,
                routing_key=routing_key,
                envelope=row.payload,
                headers=headers,
            )
        except Exception as exc:  # noqa: BLE001 - any publish failure is retryable
            row.attempts += 1
            row.last_error = str(exc)[:2000]
            db.commit()
            LOGGER.warning(
                "publish failed outbox_id=%s event_id=%s routing_key=%s: %s",
                row.id,
                row.event_id,
                routing_key,
                exc,
            )
            return False

        row.state = OutboxState.SENT.value
        row.published_at = utcnow()
        row.attempts += 1
        row.last_error = None
        if row.retry_attempt:
            db.execute(
                update(RetryJob)
                .where(
                    RetryJob.event_id == row.event_id,
                    RetryJob.attempt == row.retry_attempt,
                    RetryJob.status == RetryJobStatus.PENDING.value,
                )
                .values(status=RetryJobStatus.PUBLISHED.value)
            )
        db.commit()
        LOGGER.info(
            "published outbox_id=%s event_id=%s type=%s routing_key=%s retry_attempt=%s",
            row.id,
            row.event_id,
            row.event_type,
            routing_key,
            row.retry_attempt,
        )
        return True
    except SQLAlchemyError:
        db.rollback()
        LOGGER.exception("dispatcher database error outbox_id=%s", row_id)
        return False
    finally:
        db.close()


async def drain_once(channel) -> int:
    """One dispatch pass: publish every due PENDING row; returns successes."""
    published = 0
    for row_id in _due_row_ids():
        if await _publish_row(channel, row_id):
            published += 1
    return published


async def run_dispatcher() -> None:
    settings = get_settings()
    connection = await aio_pika.connect_robust(
        settings.amqp_url, timeout=settings.amqp_connect_timeout_s
    )
    # on_return_raises=True: a mandatory publish with no matching binding
    # raises PublishError instead of silently "succeeding" — without it an
    # unroutable event could be marked SENT and lost.
    channel = await connection.channel(
        publisher_confirms=True, on_return_raises=True
    )
    # Declare the topology first so mandatory publishes always have a binding
    # to land on, even when all workers are still starting.
    await declare_topology(channel)
    LOGGER.info("outbox dispatcher started")
    while True:
        try:
            published = await drain_once(channel)
        except SQLAlchemyError:
            LOGGER.exception("outbox dispatcher poll failed")
            published = 0
        if published == 0:
            await asyncio.sleep(POLL_INTERVAL_S)


def main() -> None:
    settings = get_settings()
    logging.basicConfig(
        level=settings.log_level,
        format="%(asctime)s %(levelname)-7s %(name)s %(message)s",
    )
    asyncio.run(run_dispatcher())


if __name__ == "__main__":
    main()
