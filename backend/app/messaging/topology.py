"""RabbitMQ topology.

``quickbite.orders`` is a durable topic exchange. Every queue is durable,
non-exclusive, and never auto-deleted, and all queues/bindings are declared
*before* any event is dispatched — so stopping a consumer never removes its
queue.

Queue -> binding -> consumer responsibility
    payment.queue      order.created    simulate payment (PENDING -> PAID|PAYMENT_FAILED)
    restaurant.queue   order.paid       simulate acceptance (PAID -> CONFIRMED|FAILED)
    delivery.queue     order.confirmed  assign driver (CONFIRMED -> DRIVER_ASSIGNED|FAILED)
    notification.queue order.#          persist notifications for ALL order events

``order.#`` (hash) matches zero or more segments and therefore covers
``order.payment.failed`` and ``order.driver.assigned``; ``order.*`` would not.

Dead-letter path: ``quickbite.dead`` (durable direct) -> ``orders.dead-letter.queue``
bound with routing key ``failed``, for quarantined envelopes.
"""

from __future__ import annotations

import aio_pika

from app.services.events import DEAD_EXCHANGE, DEAD_QUEUE, DEAD_ROUTING_KEY, ORDERS_EXCHANGE

# Exchange -> type registry: the single source of truth used by the topology
# declaration *and* by publishers (which must never re-declare an exchange
# with a different type — that kills the channel with PRECONDITION_FAILED).
EXCHANGE_TYPES: dict[str, aio_pika.ExchangeType] = {
    ORDERS_EXCHANGE: aio_pika.ExchangeType.TOPIC,
    DEAD_EXCHANGE: aio_pika.ExchangeType.DIRECT,
}

# queue name -> routing keys bound on the main topic exchange
TOPIC_BINDINGS: dict[str, tuple[str, ...]] = {
    "payment.queue": ("order.created",),
    "restaurant.queue": ("order.paid",),
    "delivery.queue": ("order.confirmed",),
    "notification.queue": ("order.#",),
}

# Retry routing goes through the *default* exchange directly to the failing
# consumer's queue, so unrelated subscribers never see it.
RETRY_QUEUES = tuple(TOPIC_BINDINGS)


async def declare_topology(channel) -> None:
    """Idempotently declare every exchange, queue, and binding."""
    orders_exchange = await channel.declare_exchange(
        ORDERS_EXCHANGE,
        aio_pika.ExchangeType.TOPIC,
        durable=True,
        auto_delete=False,
    )
    dead_exchange = await channel.declare_exchange(
        DEAD_EXCHANGE,
        aio_pika.ExchangeType.DIRECT,
        durable=True,
        auto_delete=False,
    )

    for queue_name, routing_keys in TOPIC_BINDINGS.items():
        queue = await channel.declare_queue(
            queue_name,
            durable=True,
            exclusive=False,
            auto_delete=False,
        )
        for routing_key in routing_keys:
            await queue.bind(orders_exchange, routing_key=routing_key)

    dead_queue = await channel.declare_queue(
        DEAD_QUEUE,
        durable=True,
        exclusive=False,
        auto_delete=False,
    )
    await dead_queue.bind(dead_exchange, routing_key=DEAD_ROUTING_KEY)
