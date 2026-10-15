"""Milestone 3 acceptance: the async pipeline against real Postgres + RabbitMQ.

The test environment (conftest) provisions an isolated database and vhost,
so these tests exercise the *real* consumer runtime, outbox dispatcher, and
retry scheduler without racing the developer's compose workers.

Clock: retry delays are accelerated to 0.5/1/1.5s for tests (the compose
stack runs the production 2/10/30s schedule — see docs/architecture.md).
"""

from __future__ import annotations

import asyncio
import json
import time
import uuid

import aio_pika
import pytest
from aio_pika import Message
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app.config import get_settings
from app.db import SessionLocal
from app.domain.ids import new_outbox_id
from app.messaging.topology import declare_topology
from app.main import app
from app.models import (
    DriverAssignment,
    Notification,
    Order,
    OrderStatusHistory,
    OutboxEvent,
    ProcessedEvent,
    QuarantineRecord,
    RetryJob,
    SimulatedPayment,
)
from app.services.events import build_event
from workers.handlers import DELIVERY, NOTIFICATION, PAYMENT, RESTAURANT
from workers.outbox_dispatcher import drain_once
from workers.retry_scheduler import _release_due as release_due
from workers.runtime import _process as process_delivery
from workers.runtime import attempt_of, start_consumer, validate_envelope

STAGES = (PAYMENT, RESTAURANT, DELIVERY, NOTIFICATION)

CUSTOMER = {"email": "maya@quickbite.dev", "password": "demo12345"}


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

@pytest.fixture()
def client() -> TestClient:
    with TestClient(app) as test_client:
        yield test_client


def _auth(client: TestClient) -> dict:
    response = client.post("/api/v1/auth/login", json=CUSTOMER)
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


def _place_order(client: TestClient, auth: dict) -> str:
    restaurants = client.get("/api/v1/restaurants", headers=auth).json()["items"]
    rest = restaurants[0]
    menu = client.get(
        f"/api/v1/restaurants/{rest['id']}/menu", headers=auth
    ).json()["items"]
    items = [item for item in menu if item["is_available"]][:2]
    assert len(items) == 2, "seeded menu must expose two available items"
    response = client.post(
        "/api/v1/orders",
        headers={**auth, "Idempotency-Key": str(uuid.uuid4())},
        json={
            "restaurant_id": rest["id"],
            "delivery_address": "12 Lake Road, Bengaluru",
            "items": [
                {"menu_item_id": items[0]["id"], "quantity": 2},
                {"menu_item_id": items[1]["id"], "quantity": 1},
            ],
        },
    )
    assert response.status_code == 202, response.text
    return response.json()["order_id"]


async def _pump(until, *, timeout: float = 20.0, consume: bool = True) -> None:
    """Run the real dispatcher + retry scheduler + consumers until `until()`.

    This is the same code the compose services run, just driven from the
    test loop so assertions can happen deterministically.
    """
    settings = get_settings()
    connection = await aio_pika.connect_robust(
        settings.amqp_url, timeout=settings.amqp_connect_timeout_s
    )
    try:
        channel = await connection.channel(
            publisher_confirms=True, on_return_raises=True
        )
        await channel.set_qos(prefetch_count=settings.worker_prefetch)
        await declare_topology(channel)
        if consume:
            for handler in STAGES:
                await start_consumer(handler, connection=connection)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            await drain_once(channel)
            release_due()
            if until():
                return
            await asyncio.sleep(0.1)
        raise AssertionError("pipeline did not reach the expected state in time")
    finally:
        await connection.close()


def pump(until, *, timeout: float = 20.0, consume: bool = True) -> None:
    asyncio.run(_pump(until, timeout=timeout, consume=consume))


def _order_status(order_id: str) -> str | None:
    with SessionLocal() as session:
        order = session.get(Order, order_id)
        return order.status if order else None


def _history(order_id: str) -> list[OrderStatusHistory]:
    with SessionLocal() as session:
        return list(
            session.scalars(
                select(OrderStatusHistory)
                .where(OrderStatusHistory.order_id == order_id)
                .order_by(OrderStatusHistory.version)
            ).all()
        )


def _order_outbox(order_id: str) -> list[OutboxEvent]:
    with SessionLocal() as session:
        return list(
            session.scalars(
                select(OutboxEvent).where(OutboxEvent.order_id == order_id)
            ).all()
        )


# --------------------------------------------------------------------------
# happy path
# --------------------------------------------------------------------------

class TestPipelineHappyPath:
    def test_order_flows_to_driver_assigned(
        self, client: TestClient, clean_pipeline
    ) -> None:
        auth = _auth(client)
        order_id = _place_order(client, auth)
        assert _order_status(order_id) == "PENDING"

        pump(lambda: _order_status(order_id) == "DRIVER_ASSIGNED", timeout=25)

        # Full state machine: PENDING -> PAID -> CONFIRMED -> DRIVER_ASSIGNED
        history = _history(order_id)
        assert [(h.from_status, h.to_status) for h in history] == [
            (None, "PENDING"),
            ("PENDING", "PAID"),
            ("PAID", "CONFIRMED"),
            ("CONFIRMED", "DRIVER_ASSIGNED"),
        ]
        assert [h.source for h in history] == [
            "api",
            "payment-worker",
            "restaurant-worker",
            "delivery-worker",
        ]

        with SessionLocal() as session:
            order = session.get(Order, order_id)
            assert order is not None
            assert order.version == 4  # one bump per transition
            assert order.failure_code is None

            payment = session.scalars(
                select(SimulatedPayment).where(
                    SimulatedPayment.order_id == order_id
                )
            ).one()
            assert payment.status == "SUCCEEDED"
            assert payment.attempts == 1

            assignment = session.scalars(
                select(DriverAssignment).where(
                    DriverAssignment.order_id == order_id
                )
            ).one()
            assert assignment.driver_name

            # Every domain event the pipeline emitted was published.
            outbox = _order_outbox(order_id)
            assert {o.event_type for o in outbox} == {
                "order.created",
                "order.paid",
                "order.confirmed",
                "order.driver.assigned",
            }
            assert all(o.state == "SENT" for o in outbox)
            assert not any(o.target_queue for o in outbox), "no retries expected"

            # Dedup ledger: one row per (consumer, event).
            processed = session.scalars(
                select(ProcessedEvent).where(
                    ProcessedEvent.order_id == order_id
                )
            ).all()
            by_consumer: dict[str, int] = {}
            for row in processed:
                by_consumer[row.consumer_name] = (
                    by_consumer.get(row.consumer_name, 0) + 1
                )
            assert by_consumer == {
                "payment": 1,
                "restaurant": 1,
                "delivery": 1,
                "notification": 4,  # order.# fan-out: created/paid/confirmed/driver
            }
            assert all(row.result == "applied" for row in processed)

            # Happy path uses neither retries nor quarantine.
            assert (
                session.scalar(
                    select(func.count())
                    .select_from(RetryJob)
                    .where(RetryJob.order_id == order_id)
                )
                == 0
            )
            assert (
                session.scalar(
                    select(func.count())
                    .select_from(QuarantineRecord)
                    .where(QuarantineRecord.order_id == order_id)
                )
                == 0
            )

        # The customer-visible feed shows every stage.
        notifications = client.get(
            f"/api/v1/orders/{order_id}/notifications", headers=auth
        ).json()
        assert {n["event_type"] for n in notifications["items"]} == {
            "order.created",
            "order.paid",
            "order.confirmed",
            "order.driver.assigned",
        }

    def test_duplicate_delivery_is_acknowledged_not_reapplied(
        self, client: TestClient, clean_pipeline
    ) -> None:
        """A redelivered event is deduplicated via processed_events."""
        auth = _auth(client)
        order_id = _place_order(client, auth)

        row = next(o for o in _order_outbox(order_id) if o.event_type == "order.created")
        # Round-trip exactly what a broker delivery carries.
        envelope = json.loads(json.dumps(row.payload))

        assert process_delivery(PAYMENT, envelope, 1) == "ack"
        assert _order_status(order_id) == "PAID"
        first_outbox = len(_order_outbox(order_id))

        # Redelivery: acknowledged, no second application, no second event.
        assert process_delivery(PAYMENT, envelope, 2) == "ack"
        assert _order_status(order_id) == "PAID"
        assert len(_order_outbox(order_id)) == first_outbox

        with SessionLocal() as session:
            payments = session.scalars(
                select(SimulatedPayment).where(
                    SimulatedPayment.order_id == order_id
                )
            ).all()
            assert len(payments) == 1
            processed = session.scalars(
                select(ProcessedEvent).where(
                    ProcessedEvent.consumer_name == "payment",
                    ProcessedEvent.order_id == order_id,
                )
            ).all()
            assert len(processed) == 1
            assert processed[0].attempts == 1  # first application won

        history = _history(order_id)
        assert len(history) == 2  # PENDING creation + single PAID transition


# --------------------------------------------------------------------------
# bounded retries + quarantine
# --------------------------------------------------------------------------

class TestBoundedRetries:
    def test_payment_fail_twice_recovers_on_third_attempt(
        self, client: TestClient, clean_pipeline, payment_mode
    ) -> None:
        payment_mode("fail_twice")
        auth = _auth(client)
        order_id = _place_order(client, auth)

        pump(lambda: _order_status(order_id) == "DRIVER_ASSIGNED", timeout=30)

        with SessionLocal() as session:
            jobs = session.scalars(
                select(RetryJob)
                .where(RetryJob.order_id == order_id)
                .order_by(RetryJob.attempt)
            ).all()
            # Two failed attempts each scheduled exactly one bounded retry.
            assert [job.attempt for job in jobs] == [2, 3]
            assert all(job.status == "PUBLISHED" for job in jobs)
            assert all(job.failure_code == "payment_declined" for job in jobs)
            assert all(job.max_attempts == 3 for job in jobs)

            # The retries were published through the default exchange with
            # increasing x-attempt metadata.
            retries = [
                o
                for o in _order_outbox(order_id)
                if o.target_queue == "payment.queue"
            ]
            assert sorted(o.retry_attempt for o in retries) == [2, 3]
            assert all(o.state == "SENT" for o in retries)
            # Same immutable event_id as the original publication.
            original = next(
                o for o in _order_outbox(order_id) if o.event_type == "order.created"
            )
            assert all(o.event_id == original.event_id for o in retries)

            # Succeeded on attempt 3; the payment row proves the x-attempt
            # header reached the handler.
            payment = session.scalars(
                select(SimulatedPayment).where(
                    SimulatedPayment.order_id == order_id
                )
            ).one()
            assert payment.attempts == 3
            assert payment.status == "SUCCEEDED"

            assert (
                session.scalar(
                    select(func.count())
                    .select_from(QuarantineRecord)
                    .where(QuarantineRecord.order_id == order_id)
                )
                == 0
            ), "successful recovery must not quarantine anything"

    def test_exhausted_retries_quarantine_and_fail_the_order(
        self, client: TestClient, clean_pipeline, payment_mode
    ) -> None:
        payment_mode("fail_always")
        auth = _auth(client)
        order_id = _place_order(client, auth)

        pump(lambda: _order_status(order_id) == "PAYMENT_FAILED", timeout=30)

        history = _history(order_id)
        assert (history[-1].from_status, history[-1].to_status) == (
            "PENDING",
            "PAYMENT_FAILED",
        )
        assert history[-1].source == "payment-worker"

        with SessionLocal() as session:
            order = session.get(Order, order_id)
            assert order is not None
            assert order.failure_code == "payment_declined"

            # 1 immediate attempt + 3 delayed retries, then quarantine.
            jobs = session.scalars(
                select(RetryJob)
                .where(RetryJob.order_id == order_id)
                .order_by(RetryJob.attempt)
            ).all()
            assert [job.attempt for job in jobs] == [2, 3, 4]
            assert all(job.status == "PUBLISHED" for job in jobs)

            quarantine = session.scalars(
                select(QuarantineRecord).where(
                    QuarantineRecord.order_id == order_id
                )
            ).one()
            assert quarantine.consumer_name == "payment"
            assert quarantine.status == "OPEN"
            assert quarantine.attempts == 4
            assert quarantine.failure_code == "payment_declined"
            assert quarantine.source_queue == "payment.queue"
            assert quarantine.envelope["event_id"]

            processed = session.scalars(
                select(ProcessedEvent).where(
                    ProcessedEvent.consumer_name == "payment",
                    ProcessedEvent.order_id == order_id,
                )
            ).one()
            assert processed.result == "quarantined"

            # Terminal failure event + dead-letter copy both published.
            types = {o.event_type for o in _order_outbox(order_id)}
            assert "order.payment.failed" in types
            dead = session.scalars(
                select(OutboxEvent).where(
                    OutboxEvent.exchange == "quickbite.dead",
                    OutboxEvent.order_id == order_id,
                )
            ).all()
            assert dead and all(o.state == "SENT" for o in dead)

        notifications = client.get(
            f"/api/v1/orders/{order_id}/notifications", headers=auth
        ).json()
        assert any(
            n["event_type"] == "order.payment.failed"
            for n in notifications["items"]
        ), "customer must learn the payment failed"


# --------------------------------------------------------------------------
# malformed input + mandatory publishing
# --------------------------------------------------------------------------

class TestFailureModes:
    def test_malformed_body_is_quarantined_not_retried(
        self, clean_pipeline
    ) -> None:
        async def _send_garbage() -> None:
            settings = get_settings()
            connection = await aio_pika.connect_robust(
                settings.amqp_url, timeout=settings.amqp_connect_timeout_s
            )
            try:
                channel = await connection.channel(
                    publisher_confirms=True, on_return_raises=True
                )
                await declare_topology(channel)
                await channel.default_exchange.publish(
                    Message(
                        b"{not-json",
                        content_type="application/json",
                        message_id="evt_garbage_should_not_parse",
                    ),
                    routing_key="payment.queue",
                    mandatory=True,
                )
            finally:
                await connection.close()

        asyncio.run(_send_garbage())

        def _quarantined() -> bool:
            with SessionLocal() as session:
                row = session.scalar(
                    select(QuarantineRecord).where(
                        QuarantineRecord.failure_code == "malformed_envelope"
                    )
                )
                return row is not None

        pump(_quarantined, timeout=15)

        with SessionLocal() as session:
            row = session.scalar(
                select(QuarantineRecord).where(
                    QuarantineRecord.failure_code == "malformed_envelope"
                )
            )
            assert row is not None
            assert row.consumer_name == "payment"
            assert row.source_queue == "payment.queue"
            assert "{not-json" in row.envelope["data"]["raw"]
            # The dead-letter copy was published to quickbite.dead.
            dead = session.scalars(
                select(OutboxEvent).where(
                    OutboxEvent.exchange == "quickbite.dead",
                    OutboxEvent.event_type == "malformed",
                )
            ).all()
            assert dead and all(o.state == "SENT" for o in dead)
            # Nothing was retried for a malformed body.
            assert (
                session.scalar(select(func.count()).select_from(RetryJob)) == 0
            )

    def test_unroutable_event_stays_pending_with_error(self, clean_pipeline) -> None:
        """mandatory=True: an event without a matching binding never becomes
        SENT — it stays PENDING with the error recorded for retry.

        The routing key deliberately avoids the ``order.#`` prefix so no
        binding on the topic exchange can match it."""
        event = build_event(
            event_type="billing.unknown.event",
            order_id="order_unroutable_test",
            order_version=1,
            data={"probe": True},
        )
        with SessionLocal() as session:
            session.add(
                OutboxEvent(
                    id=new_outbox_id(),
                    event_id=event["event_id"],
                    schema_version=event["schema_version"],
                    event_type=event["event_type"],
                    order_id=event["order_id"],
                    order_version=event["order_version"],
                    exchange="quickbite.orders",
                    routing_key="billing.unknown.event",
                    payload=event,
                )
            )
            session.commit()
            row_id = session.scalar(
                select(OutboxEvent.id).where(
                    OutboxEvent.event_id == event["event_id"]
                )
            )

        async def _drain_once() -> None:
            settings = get_settings()
            connection = await aio_pika.connect_robust(
                settings.amqp_url, timeout=settings.amqp_connect_timeout_s
            )
            try:
                channel = await connection.channel(
                    publisher_confirms=True, on_return_raises=True
                )
                await declare_topology(channel)
                await drain_once(channel)
            finally:
                await connection.close()

        asyncio.run(_drain_once())

        with SessionLocal() as session:
            row = session.get(OutboxEvent, row_id)
            assert row is not None
            assert row.state == "PENDING", "unroutable must not be marked SENT"
            assert row.attempts >= 1
            assert row.last_error, "publish failure must be recorded"


# --------------------------------------------------------------------------
# envelope validation (unit)
# --------------------------------------------------------------------------

class TestEnvelopeValidation:
    def _envelope(self) -> dict:
        return build_event(
            event_type="order.created",
            order_id="order_x",
            order_version=1,
            data={},
        )

    def test_valid_envelope_passes(self) -> None:
        raw = json.dumps(self._envelope()).encode()
        assert validate_envelope(raw)["event_id"].startswith("evt_")

    @pytest.mark.parametrize(
        "mutate, reason",
        [
            (lambda e: e.pop("event_id"), "missing event_id"),
            (lambda e: e.pop("schema_version"), "missing schema_version"),
            (lambda e: e.update(schema_version="1"), "schema_version type"),
            (lambda e: e.update(order_id=""), "empty order_id"),
            (lambda e: e.update(event_type=7), "event_type type"),
        ],
    )
    def test_invalid_envelopes_rejected(self, mutate, reason: str) -> None:
        envelope = self._envelope()
        mutate(envelope)
        with pytest.raises(ValueError):
            validate_envelope(json.dumps(envelope).encode())

    def test_unparseable_body_rejected(self) -> None:
        with pytest.raises(ValueError):
            validate_envelope(b"\xff\xfe not json")

    def test_non_object_body_rejected(self) -> None:
        with pytest.raises(ValueError):
            validate_envelope(b"[1, 2, 3]")

    def test_attempt_header_defaults_and_parses(self) -> None:
        class FakeMessage:
            def __init__(self, headers):
                self.headers = headers

        assert attempt_of(FakeMessage(None)) == 1
        assert attempt_of(FakeMessage({})) == 1
        assert attempt_of(FakeMessage({"x-attempt": 3})) == 3
        assert attempt_of(FakeMessage({"x-attempt": "bogus"})) == 1
        assert attempt_of(FakeMessage({"x-attempt": 0})) == 1
