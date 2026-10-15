"""Retry scheduler: releases due scheduled retries to the publisher.

On transient failure a worker persists a ``retry_jobs`` row plus a
SCHEDULED outbox row targeted at its own queue (see ``workers.runtime``).
This loop flips both to publishable state when the due time arrives —
outbox SCHEDULED -> PENDING — so retries go out through the same confirmed
dispatcher path as every other event. The retry job stays PENDING until
the dispatcher confirms publication, then becomes PUBLISHED.

Purely database-driven: no broker connection is needed here, and releasing
a retry is idempotent (row states only move forward).
"""

from __future__ import annotations

import asyncio
import logging

from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError

from app.config import get_settings
from app.db import SessionLocal
from app.domain.enums import OutboxState, RetryJobStatus
from app.models import OutboxEvent, RetryJob, utcnow

LOGGER = logging.getLogger("quickbite.retries")

POLL_INTERVAL_S = 0.25
BATCH_SIZE = 50


def _release_due() -> int:
    """Flip due SCHEDULED retry rows to PENDING; returns rows released."""
    released = 0
    with SessionLocal() as db:
        jobs = db.execute(
            select(RetryJob)
            .where(
                RetryJob.status == RetryJobStatus.PENDING.value,
                RetryJob.scheduled_at <= utcnow(),
            )
            .order_by(RetryJob.scheduled_at)
            .limit(BATCH_SIZE)
            .with_for_update(skip_locked=True)
        ).scalars().all()
        for job in jobs:
            row = db.execute(
                select(OutboxEvent)
                .where(
                    OutboxEvent.event_id == job.event_id,
                    OutboxEvent.retry_attempt == job.attempt,
                )
                .with_for_update()
            ).scalar_one_or_none()
            if row is None:
                job.status = RetryJobStatus.CANCELLED.value  # nothing to publish
            elif row.state == OutboxState.SCHEDULED.value:
                row.state = OutboxState.PENDING.value
                released += 1
            elif row.state == OutboxState.SENT.value:
                job.status = RetryJobStatus.PUBLISHED.value  # already out
            # PENDING: already released by a previous tick — nothing to do.
        db.commit()
    return released


async def run_scheduler() -> None:
    LOGGER.info("retry scheduler started")
    while True:
        try:
            released = _release_due()
            if released:
                LOGGER.info("released %s due retries to the dispatcher", released)
        except SQLAlchemyError:
            LOGGER.exception("retry scheduler poll failed")
        await asyncio.sleep(POLL_INTERVAL_S)


def main() -> None:
    settings = get_settings()
    logging.basicConfig(
        level=settings.log_level,
        format="%(asctime)s %(levelname)-7s %(name)s %(message)s",
    )
    asyncio.run(run_scheduler())


if __name__ == "__main__":
    main()
