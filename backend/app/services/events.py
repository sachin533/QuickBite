"""Event envelope construction and the transactional outbox writer.

Every domain event carries an immutable identity:

    event_id, schema_version, event_type, order_id, order_version,
    occurred_at, correlation_id, causation_id, data

``event_id`` doubles as the AMQP ``message_id`` and as the downstream
idempotency identifier — it survives redelivery and retries; retry attempts
belong to delivery metadata, never to a new event identity.

Writing the outbox row happens in the *same* transaction as the domain
change, so an accepted order can never exist without its event (or vice
versa).
"""

from __future__ import annotations

import datetime as dt
from typing import Any

from sqlalchemy.orm import Session

from app.domain.ids import new_event_id, new_outbox_id
from app.models import OutboxEvent

SCHEMA_VERSION = 1

# Main topic exchange and its routing keys.
ORDERS_EXCHANGE = "quickbite.orders"
# Dead-letter exchange for quarantined envelopes (direct, routing key "failed").
DEAD_EXCHANGE = "quickbite.dead"
DEAD_QUEUE = "orders.dead-letter.queue"
DEAD_ROUTING_KEY = "failed"


def build_event(
    *,
    event_type: str,
    order_id: str,
    order_version: int,
    data: dict[str, Any],
    correlation_id: str | None = None,
    causation_id: str | None = None,
    event_id: str | None = None,
) -> dict[str, Any]:
    """Build a canonical event envelope (JSON-serializable)."""
    return {
        "event_id": event_id or new_event_id(),
        "schema_version": SCHEMA_VERSION,
        "event_type": event_type,
        "order_id": order_id,
        "order_version": order_version,
        "occurred_at": dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "correlation_id": correlation_id,
        "causation_id": causation_id,
        "data": data,
    }


def enqueue_event(
    db: Session,
    *,
    event: dict[str, Any],
    routing_key: str,
    exchange: str = ORDERS_EXCHANGE,
    target_queue: str | None = None,
    available_at: dt.datetime | None = None,
    order_version: int | None = None,
) -> OutboxEvent:
    """Persist an outgoing event in the transactional outbox.

    Must be called with the domain change in the same transaction/session.
    The dispatcher later publishes it with publisher confirms + mandatory
    routing and marks it SENT only after an unambiguous confirm.
    """
    record = OutboxEvent(
        id=new_outbox_id(),
        event_id=event["event_id"],
        schema_version=int(event["schema_version"]),
        event_type=event["event_type"],
        order_id=event.get("order_id"),
        order_version=order_version if order_version is not None else event.get("order_version"),
        correlation_id=event.get("correlation_id"),
        causation_id=event.get("causation_id"),
        exchange=exchange,
        routing_key=routing_key,
        # Non-None only for retries: publish through the default exchange
        # directly to the failing consumer's queue (never re-broadcast).
        target_queue=target_queue,
        payload=event,
        available_at=available_at or dt.datetime.now(dt.timezone.utc),
    )
    db.add(record)
    return record
