"""Shared consumer runtime for all four stage workers.

Per-delivery sequence (assignment M3):

    1. parse + validate the envelope — malformed bodies are quarantined
       (dead-lettered) and acknowledged, never retried;
    2. simulate stage latency *before* opening the transaction, so row locks
       are never held during a simulated delay;
    3. open one transaction and lock the order row (``SELECT ... FOR
       UPDATE``) so concurrent deliveries for the same order serialize;
    4. check ``processed_events`` — duplicates are acknowledged, never
       re-applied;
    5. classify the current state (``StaleEvent`` -> no-op ack,
       ``PrerequisitePending`` -> bounded retry);
    6. apply the stage effect + status transition + child outbox event in
       the *same* transaction;
    7. record ``processed_events``, commit, ack.

Failure classes:

    TransientProcessingError -> bounded retry: a ``retry_jobs`` row plus a
        SCHEDULED outbox row targeted at this queue via the default exchange
        (delay from RETRY_DELAYS_SECONDS), then ack — the retry is durably
        persisted before the original delivery is acknowledged. Once attempts
        are exhausted the event is quarantined with a terminal transition.
    PrerequisitePending      -> same bounded retry path (out-of-order arrival).
    StaleEvent               -> no-op, ack, recorded as ``stale``.
    InvalidTransition        -> quarantine (state-machine bug, not retryable).
    SQLAlchemyError / crash  -> rollback + nack(requeue): an unexpected
        database error is never acknowledged away.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import hashlib
import json
import logging
from typing import Any

import aio_pika
from aio_pika import IncomingMessage
from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import SessionLocal
from app.domain.enums import OutboxState, RetryJobStatus
from app.domain.ids import new_quarantine_id, new_retry_job_id
from app.domain.state_machine import InvalidTransition
from app.messaging.topology import DEAD_EXCHANGE, DEAD_ROUTING_KEY, declare_topology
from app.models import Order, OutboxEvent, ProcessedEvent, QuarantineRecord, RetryJob, utcnow
from app.services.events import build_event, enqueue_event
from app.services.transitions import PrerequisitePending, StaleEvent, expected_state
from workers.handlers import StageHandler, TransientProcessingError

LOGGER = logging.getLogger("quickbite.workers")

# Backoff before nack(requeue) on unexpected errors: keeps a poisoned message
# from hot-looping while guaranteeing it is never acknowledged away.
REQUEUE_BACKOFF_S = 2.0

# String-typed identity fields that must be present on every envelope.
# (schema_version is validated separately as an integer.)
REQUIRED_ENVELOPE_FIELDS = ("event_id", "event_type", "order_id")


# --------------------------------------------------------------------------
# envelope validation
# --------------------------------------------------------------------------

def validate_envelope(raw: bytes) -> dict[str, Any]:
    """Parse and structurally validate a delivery body.

    Raises :class:`ValueError` for anything that must be quarantined instead
    of retried (unparseable JSON, missing identity fields, wrong types).
    """
    try:
        envelope = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"body is not valid JSON: {exc}") from exc
    if not isinstance(envelope, dict):
        raise ValueError("envelope must be a JSON object")
    for field in REQUIRED_ENVELOPE_FIELDS:
        value = envelope.get(field)
        if not isinstance(value, str) or not value:
            raise ValueError(f"missing or invalid field {field!r}")
    if not isinstance(envelope.get("schema_version"), int):
        raise ValueError("schema_version must be an integer")
    return envelope


def attempt_of(message: IncomingMessage) -> int:
    """Current delivery attempt from the x-attempt retry header (1 = first)."""
    headers = message.headers or {}
    try:
        return max(1, int(headers.get("x-attempt", 1)))
    except (TypeError, ValueError):
        return 1


# --------------------------------------------------------------------------
# database helpers (each runs in its own session/transaction)
# --------------------------------------------------------------------------

def _lock_order(db: Session, order_id: str | None) -> Order | None:
    if not order_id:
        return None
    return db.execute(
        select(Order).where(Order.id == order_id).with_for_update()
    ).scalar_one_or_none()


def _already_processed(db: Session, consumer_name: str, event_id: str) -> bool:
    row = db.execute(
        select(ProcessedEvent.id).where(
            ProcessedEvent.consumer_name == consumer_name,
            ProcessedEvent.event_id == event_id,
        )
    ).first()
    return row is not None


def _record_processed(
    db: Session, handler: StageHandler, envelope: dict[str, Any], *, result: str, attempt: int
) -> None:
    db.add(
        ProcessedEvent(
            consumer_name=handler.consumer_name,
            event_id=envelope["event_id"],
            event_type=envelope["event_type"],
            order_id=envelope.get("order_id"),
            result=result,
            attempts=attempt,
        )
    )


def _schedule_retry(
    handler: StageHandler, envelope: dict[str, Any], attempt: int, code: str, reason: str
) -> bool:
    """Persist a bounded retry; returns False when attempts are exhausted.

    Writes a ``retry_jobs`` row *and* a SCHEDULED outbox row targeted at this
    consumer's queue through the default exchange, with ``retry_attempt`` so
    the retry is published with the ``x-attempt`` header. Same immutable
    event_id — retry attempts are delivery metadata, not a new event.
    """
    settings = get_settings()
    if attempt - 1 >= settings.retry_max_attempts:
        return False
    delays = settings.retry_delay_list
    delay_s = delays[min(attempt - 1, len(delays) - 1)]
    due = utcnow() + dt.timedelta(seconds=delay_s)
    with SessionLocal() as db:
        db.add(
            RetryJob(
                id=new_retry_job_id(),
                consumer_name=handler.consumer_name,
                event_id=envelope["event_id"],
                event_type=envelope["event_type"],
                order_id=envelope.get("order_id"),
                attempt=attempt + 1,
                max_attempts=settings.retry_max_attempts,
                failure_code=code,
                failure_reason=reason[:2000],
                status=RetryJobStatus.PENDING.value,
                scheduled_at=due,
            )
        )
        # The original envelope is republished verbatim (identical event_id).
        enqueue_event(
            db,
            event=envelope,
            routing_key=handler.queue,
            exchange="",  # default exchange: routing key == queue name
            target_queue=handler.queue,
            available_at=due,
            order_version=envelope.get("order_version"),
            state=OutboxState.SCHEDULED,
            retry_attempt=attempt + 1,
        )
        db.commit()
    LOGGER.info(
        "retry scheduled consumer=%s event_id=%s order_id=%s attempt=%s in=%.1fs code=%s",
        handler.consumer_name,
        envelope["event_id"],
        envelope.get("order_id"),
        attempt + 1,
        delay_s,
        code,
    )
    return True


def _dead_letter_copy(
    db: Session,
    handler: StageHandler,
    envelope: dict[str, Any],
    *,
    attempt: int,
    code: str,
    reason: str,
) -> None:
    """Enqueue the dead-letter copy of the envelope on ``quickbite.dead``."""
    dead_copy = build_event(
        event_type=envelope.get("event_type", "unknown"),
        order_id=envelope.get("order_id", ""),
        order_version=envelope.get("order_version"),
        correlation_id=envelope.get("correlation_id"),
        causation_id=envelope.get("event_id"),
        event_id=envelope["event_id"],
        data={
            "consumer": handler.consumer_name,
            "source_queue": handler.queue,
            "failure_code": code,
            "failure_reason": reason[:500],
            "attempts": attempt,
            "original": envelope,
        },
    )
    enqueue_event(db, event=dead_copy, exchange=DEAD_EXCHANGE, routing_key=DEAD_ROUTING_KEY)


def _quarantine(
    handler: StageHandler,
    envelope: dict[str, Any],
    *,
    attempt: int,
    code: str,
    reason: str,
) -> None:
    """Dead-letter the envelope: DB ledger row + copy on the dead exchange."""
    with SessionLocal() as db:
        db.add(
            QuarantineRecord(
                id=new_quarantine_id(),
                event_id=envelope["event_id"],
                event_type=envelope.get("event_type"),
                order_id=envelope.get("order_id"),
                consumer_name=handler.consumer_name,
                source_queue=handler.queue,
                attempts=attempt,
                failure_code=code,
                failure_reason=reason[:2000],
                envelope=envelope,
                status="OPEN",
            )
        )
        _dead_letter_copy(db, handler, envelope, attempt=attempt, code=code, reason=reason)
        db.commit()
    LOGGER.warning(
        "quarantined consumer=%s event_id=%s order_id=%s code=%s reason=%s",
        handler.consumer_name,
        envelope["event_id"],
        envelope.get("order_id"),
        code,
        reason,
    )


def _quarantine_malformed(
    handler: StageHandler, message: IncomingMessage, reason: str
) -> None:
    """Quarantine a body that could not be parsed into an envelope."""
    raw = message.body.decode("utf-8", errors="replace")
    event_id = message.message_id or (
        "malformed_" + hashlib.sha256(message.body).hexdigest()[:32]
    )
    envelope: dict[str, Any] = {
        "event_id": event_id,
        "schema_version": 0,
        "event_type": "malformed",
        "order_id": "",
        "order_version": None,
        "correlation_id": None,
        "causation_id": None,
        "data": {"raw": raw[:8000]},
    }
    _quarantine(
        handler, envelope, attempt=1, code="malformed_envelope", reason=reason
    )


def _handle_exhausted(
    handler: StageHandler, envelope: dict[str, Any], attempt: int, code: str, reason: str
) -> None:
    """Retries exhausted: terminal transition (where appropriate) + quarantine.

    All in one transaction: order lock, terminal transition + failure event
    (payment -> PAYMENT_FAILED + order.payment.failed, other stages ->
    FAILED + order.failed), quarantine ledger row, processed_events marker.
    Notification failures quarantine without touching the order.
    """
    with SessionLocal() as db:
        order = _lock_order(db, envelope.get("order_id"))
        if _already_processed(db, handler.consumer_name, envelope["event_id"]):
            db.rollback()
            return
        if order is not None and handler.on_exhausted is not None:
            try:
                handler.on_exhausted(db, order, envelope, code, reason)
            except InvalidTransition as exc:
                # Order already moved past this stage; still dead-letter the event.
                LOGGER.warning(
                    "terminal transition skipped consumer=%s event_id=%s: %s",
                    handler.consumer_name,
                    envelope["event_id"],
                    exc,
                )
        db.add(
            QuarantineRecord(
                id=new_quarantine_id(),
                event_id=envelope["event_id"],
                event_type=envelope.get("event_type"),
                order_id=envelope.get("order_id"),
                consumer_name=handler.consumer_name,
                source_queue=handler.queue,
                attempts=attempt,
                failure_code=code,
                failure_reason=reason[:2000],
                envelope=envelope,
                status="OPEN",
            )
        )
        _dead_letter_copy(db, handler, envelope, attempt=attempt, code=code, reason=reason)
        _record_processed(db, handler, envelope, result="quarantined", attempt=attempt)
        db.commit()
    LOGGER.warning(
        "retries exhausted consumer=%s event_id=%s order_id=%s attempts=%s code=%s",
        handler.consumer_name,
        envelope["event_id"],
        envelope.get("order_id"),
        attempt,
        code,
    )


# --------------------------------------------------------------------------
# single-message processing (synchronous; called from the async consumer)
# --------------------------------------------------------------------------

def _process(handler: StageHandler, envelope: dict[str, Any], attempt: int) -> str:
    """Process one validated delivery. Returns ``"ack"`` or ``"requeue"``."""
    event_id = envelope["event_id"]
    db = SessionLocal()
    try:
        order = _lock_order(db, envelope.get("order_id"))
        if _already_processed(db, handler.consumer_name, event_id):
            db.rollback()
            LOGGER.info(
                "duplicate ignored consumer=%s event_id=%s order_id=%s",
                handler.consumer_name,
                event_id,
                envelope.get("order_id"),
            )
            return "ack"
        if handler.expected is not None and order is None:
            raise TransientProcessingError(
                "missing_order", f"order {envelope.get('order_id')!r} not found"
            )
        if handler.expected is not None:
            # Raises StaleEvent (no-op) or PrerequisitePending (retry).
            expected_state(order, handler.expected)
        outcome = handler.apply(db, order, envelope, attempt)
        _record_processed(db, handler, envelope, result=outcome, attempt=attempt)
        db.commit()
        LOGGER.info(
            "processed consumer=%s event_id=%s order_id=%s result=%s attempt=%s",
            handler.consumer_name,
            event_id,
            envelope.get("order_id"),
            outcome,
            attempt,
        )
        return "ack"
    except StaleEvent as exc:
        db.rollback()
        LOGGER.info(
            "stale event consumer=%s event_id=%s order_id=%s: %s",
            handler.consumer_name,
            event_id,
            envelope.get("order_id"),
            exc,
        )
        try:
            with SessionLocal() as fresh:
                if not _already_processed(fresh, handler.consumer_name, event_id):
                    _record_processed(fresh, handler, envelope, result="stale", attempt=attempt)
        except SQLAlchemyError:
            LOGGER.exception("could not record stale result for %s", event_id)
        return "ack"
    except (TransientProcessingError, PrerequisitePending) as exc:
        db.rollback()
        code = getattr(exc, "code", "prerequisite_pending")
        reason = str(exc)
        try:
            if _schedule_retry(handler, envelope, attempt, code, reason):
                return "ack"
            _handle_exhausted(handler, envelope, attempt, code, reason)
            return "ack"
        except SQLAlchemyError:
            LOGGER.exception(
                "retry bookkeeping failed consumer=%s event_id=%s",
                handler.consumer_name,
                event_id,
            )
            return "requeue"
    except InvalidTransition as exc:
        db.rollback()
        LOGGER.error(
            "invalid transition consumer=%s event_id=%s order_id=%s: %s",
            handler.consumer_name,
            event_id,
            envelope.get("order_id"),
            exc,
        )
        _quarantine(handler, envelope, attempt=attempt, code="invalid_transition", reason=str(exc))
        return "ack"
    except SQLAlchemyError:
        # Unexpected database error: roll back and requeue — never acked away.
        db.rollback()
        LOGGER.exception(
            "database error consumer=%s event_id=%s order_id=%s — requeueing",
            handler.consumer_name,
            event_id,
            envelope.get("order_id"),
        )
        return "requeue"
    finally:
        db.close()


async def _on_message(handler: StageHandler, message: IncomingMessage) -> str:
    """Validate + process one delivery; returns ``"ack"`` or ``"requeue"``."""
    try:
        envelope = validate_envelope(message.body)
    except ValueError as exc:
        LOGGER.warning("malformed delivery on %s: %s", handler.queue, exc)
        try:
            _quarantine_malformed(handler, message, str(exc))
        except SQLAlchemyError:
            LOGGER.exception("quarantine write failed; requeueing")
            return "requeue"
        return "ack"

    attempt = attempt_of(message)
    # Simulation latency before the transaction (locks are never held while
    # sleeping).
    if handler.delay_ms > 0:
        await asyncio.sleep(handler.delay_ms / 1000)
    return _process(handler, envelope, attempt)


# --------------------------------------------------------------------------
# consumer bootstrap
# --------------------------------------------------------------------------

async def start_consumer(
    handler: StageHandler, *, connection=None
):
    """Declare topology and register the consumer; returns the connection.

    Split from :func:`run_consumer` so tests can run real consumers against
    the live broker and close the connection themselves. Each consumer gets
    its own channel (prefetch is per-channel), exactly like production.
    """
    settings = get_settings()
    if connection is None:
        connection = await aio_pika.connect_robust(
            settings.amqp_url, timeout=settings.amqp_connect_timeout_s
        )
    channel = await connection.channel(publisher_confirms=True)
    await channel.set_qos(prefetch_count=settings.worker_prefetch)
    await declare_topology(channel)
    queue = await channel.declare_queue(
        handler.queue, durable=True, exclusive=False, auto_delete=False
    )

    async def _callback(message: IncomingMessage) -> None:
        try:
            verdict = await _on_message(handler, message)
        except Exception:  # noqa: BLE001 - a handler bug must not strand a message
            LOGGER.exception(
                "unexpected consumer error consumer=%s message_id=%s",
                handler.consumer_name,
                message.message_id,
            )
            verdict = "requeue"
        if verdict == "ack":
            await message.ack()
        else:
            # Redelivery is the point: an unexpected failure is requeued,
            # never acknowledged away.
            await asyncio.sleep(REQUEUE_BACKOFF_S)
            await message.nack(requeue=True)

    await queue.consume(_callback, no_ack=False)
    LOGGER.info(
        "worker %s consuming queue=%s prefetch=%s",
        handler.consumer_name,
        handler.queue,
        settings.worker_prefetch,
    )
    return connection


async def run_consumer(handler: StageHandler) -> None:
    await start_consumer(handler)
    await asyncio.Future()  # run until cancelled


def main(handler: StageHandler) -> None:
    """Entrypoint for every stage worker (``python -m workers.<stage>``)."""
    settings = get_settings()
    logging.basicConfig(
        level=settings.log_level,
        format="%(asctime)s %(levelname)-7s %(name)s %(message)s",
    )
    asyncio.run(run_consumer(handler))
