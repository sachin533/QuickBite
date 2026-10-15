"""Confirmed publication helpers.

Rules enforced here:

* persistent delivery mode + JSON content type;
* AMQP ``message_id`` == the immutable ``event_id`` (idempotency identifier);
* publisher confirms are awaited;
* ``mandatory=True`` so an unroutable publish is *not* mistaken for success —
  a confirm alone only proves the broker accepted the frame, not that a
  binding existed. With ``on_return_raises=True`` the awaited publish raises
  ``PublishError`` for unroutable messages, which the dispatcher treats as a
  failure and retries later.
"""

from __future__ import annotations

import json
import logging
from typing import Any

import aio_pika
from aio_pika import DeliveryMode, Message

from app.messaging.topology import EXCHANGE_TYPES

LOGGER = logging.getLogger("quickbite.publisher")


def build_message(
    envelope: dict[str, Any],
    *,
    headers: dict[str, Any] | None = None,
    expiration_s: int | None = None,
) -> Message:
    body = json.dumps(envelope, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return Message(
        body,
        content_type="application/json",
        content_encoding="utf-8",
        delivery_mode=DeliveryMode.PERSISTENT,
        message_id=envelope.get("event_id"),
        correlation_id=envelope.get("correlation_id"),
        timestamp=None,
        headers=headers or {},
        expiration=expiration_s,
    )


async def publish_confirmed(
    channel,
    *,
    exchange_name: str,
    routing_key: str,
    envelope: dict[str, Any],
    headers: dict[str, Any] | None = None,
) -> None:
    """Publish and wait for the broker's confirm.

    Raises on failure (connection loss, channel error, or unroutable
    mandatory message) so the caller can keep the record eligible for retry.

    Requires the channel to be opened with ``publisher_confirms=True`` *and*
    ``on_return_raises=True`` — aio-pika captures both at channel-open time,
    and without the latter a returned (unroutable) mandatory message would
    not raise. Misconfigured channels fail fast here.
    """
    if not getattr(channel, "publisher_confirms", False):
        raise RuntimeError(
            "publish_confirmed requires a channel opened with "
            "publisher_confirms=True"
        )
    if not getattr(channel, "on_return_raises", False):
        raise RuntimeError(
            "publish_confirmed requires a channel opened with "
            "on_return_raises=True so unroutable mandatory publishes raise "
            "PublishError instead of silently succeeding"
        )
    if exchange_name == "":
        # Default exchange: routing key is the queue name (targeted retries).
        exchange = channel.default_exchange
    else:
        # Publish-only handle: the topology (declared at worker/dispatcher
        # startup) owns exchange declarations — never redeclare here, or a
        # type mismatch would kill the channel instead of failing one message.
        exchange = aio_pika.Exchange(
            channel,
            exchange_name,
            EXCHANGE_TYPES.get(exchange_name, aio_pika.ExchangeType.TOPIC),
        )
    await exchange.publish(
        build_message(envelope, headers=headers),
        routing_key=routing_key,
        mandatory=True,
        timeout=10,
    )
    LOGGER.debug(
        "published event_id=%s type=%s exchange=%s routing_key=%s",
        envelope.get("event_id"),
        envelope.get("event_type"),
        exchange_name,
        routing_key,
    )
