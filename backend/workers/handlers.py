"""Stage handlers: the business effect of each worker.

All handlers run inside the consumer transaction *after* the order row has
been locked and *before* ``processed_events`` is written. Simulation latency
happens before the transaction opens so row locks are never held during a
simulated delay.

Failure classes:
    TransientProcessingError   -> bounded retry, then quarantine + terminal
    PermanentProcessingError   -> skip retries, quarantine + terminal now
    (StaleEvent / PrerequisitePending from the transition service)
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from dataclasses import dataclass
from typing import Callable

from sqlalchemy.orm import Session

from app.config import get_settings
from app.domain.enums import OrderStatus
from app.domain.ids import new_assignment_id, new_notification_id, new_payment_id
from app.models import DriverAssignment, Notification, Order, SimulatedPayment
from app.services.events import build_event, enqueue_event
from app.services.transitions import apply_transition, expected_state

LOGGER = logging.getLogger("quickbite.workers")


class TransientProcessingError(Exception):
    """Retryable failure: no business effect was committed."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class PermanentProcessingError(Exception):
    """Business decline that must not be retried."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class StageHandler:
    """One processing stage (payment / restaurant / delivery / notification)."""

    consumer_name: str
    queue: str
    # Expected order status before acting (None = notification: no transition).
    expected: OrderStatus | None
    # Simulated latency for this stage (deterministic demo control).
    delay_ms: int
    apply: Callable[[Session, Order | None, dict, int], str]
    # Terminal outcome when retries are exhausted (may be None).
    on_exhausted: Callable[[Session, Order | None, dict, str, str], None] | None = None


# --------------------------------------------------------------------------
# payment
# --------------------------------------------------------------------------

def _apply_payment(db: Session, order: Order, envelope: dict, attempt: int) -> str:
    settings = get_settings()
    expected_state(order, OrderStatus.PENDING)

    mode = settings.payment_mode
    if mode == "fail_always" or (mode == "fail_twice" and attempt < 3):
        # No state change: PENDING stays PENDING while retries are scheduled.
        raise TransientProcessingError("payment_declined", "Simulated payment failure")

    # Exactly one payment row per order, enforced by the unique constraint.
    if db.query(SimulatedPayment).filter_by(order_id=order.id).first() is not None:
        return "noop"

    db.add(
        SimulatedPayment(
            id=new_payment_id(),
            order_id=order.id,
            status="SUCCEEDED",
            amount_minor=order.total_amount_minor,
            currency=order.currency,
            provider_ref=f"sim_{uuid.uuid4().hex[:16]}",
            attempts=attempt,
        )
    )
    apply_transition(
        db,
        order,
        OrderStatus.PAID,
        source="payment-worker",
        reason="Payment captured (simulated)",
        event_id=envelope.get("event_id"),
    )
    child = build_event(
        event_type="order.paid",
        order_id=order.id,
        order_version=order.version,
        correlation_id=envelope.get("correlation_id"),
        causation_id=envelope.get("event_id"),
        data={"payment_status": "SUCCEEDED", "amount_minor": order.total_amount_minor},
    )
    enqueue_event(db, event=child, routing_key="order.paid", order_version=order.version)
    return "applied"


def _payment_exhausted(
    db: Session, order: Order, envelope: dict, code: str, reason: str
) -> None:
    apply_transition(
        db,
        order,
        OrderStatus.PAYMENT_FAILED,
        source="payment-worker",
        reason=reason,
        event_id=envelope.get("event_id"),
        failure_code=code,
        failure_message=reason,
    )
    child = build_event(
        event_type="order.payment.failed",
        order_id=order.id,
        order_version=order.version,
        correlation_id=envelope.get("correlation_id"),
        causation_id=envelope.get("event_id"),
        data={"failure_code": code, "reason": reason},
    )
    enqueue_event(
        db, event=child, routing_key="order.payment.failed", order_version=order.version
    )


# --------------------------------------------------------------------------
# restaurant
# --------------------------------------------------------------------------

def _apply_restaurant(db: Session, order: Order, envelope: dict, attempt: int) -> str:
    settings = get_settings()
    expected_state(order, OrderStatus.PAID)

    if settings.restaurant_mode == "fail_always":
        raise TransientProcessingError(
            "restaurant_unavailable", "Restaurant rejected the order (simulated)"
        )

    apply_transition(
        db,
        order,
        OrderStatus.CONFIRMED,
        source="restaurant-worker",
        reason="Restaurant accepted the order",
        event_id=envelope.get("event_id"),
    )
    child = build_event(
        event_type="order.confirmed",
        order_id=order.id,
        order_version=order.version,
        correlation_id=envelope.get("correlation_id"),
        causation_id=envelope.get("event_id"),
        data={"restaurant_id": order.restaurant_id},
    )
    enqueue_event(
        db, event=child, routing_key="order.confirmed", order_version=order.version
    )
    return "applied"


def _restaurant_exhausted(
    db: Session, order: Order, envelope: dict, code: str, reason: str
) -> None:
    apply_transition(
        db,
        order,
        OrderStatus.FAILED,
        source="restaurant-worker",
        reason=reason,
        event_id=envelope.get("event_id"),
        failure_code=code,
        failure_message=reason,
    )
    child = build_event(
        event_type="order.failed",
        order_id=order.id,
        order_version=order.version,
        correlation_id=envelope.get("correlation_id"),
        causation_id=envelope.get("event_id"),
        data={"stage": "restaurant", "failure_code": code, "reason": reason},
    )
    enqueue_event(db, event=child, routing_key="order.failed", order_version=order.version)


# --------------------------------------------------------------------------
# delivery
# --------------------------------------------------------------------------

DRIVERS = [
    ("drv_arjun", "Arjun Mehta", "Bike"),
    ("drv_neha", "Neha Singh", "Scooter"),
    ("drv_kabir", "Kabir Rao", "Bike"),
    ("drv_ivy", "Ivy Thomas", "Cycle"),
]


def _apply_delivery(db: Session, order: Order, envelope: dict, attempt: int) -> str:
    settings = get_settings()
    expected_state(order, OrderStatus.CONFIRMED)

    if settings.delivery_mode == "fail_always":
        raise TransientProcessingError(
            "no_drivers_available", "No driver available (simulated)"
        )

    if db.query(DriverAssignment).filter_by(order_id=order.id).first() is not None:
        return "noop"

    driver_id, driver_name, vehicle = DRIVERS[hash(order.id) % len(DRIVERS)]
    db.add(
        DriverAssignment(
            id=new_assignment_id(),
            order_id=order.id,
            driver_id=driver_id,
            driver_name=driver_name,
            vehicle=vehicle,
        )
    )
    order.driver_id = driver_id
    apply_transition(
        db,
        order,
        OrderStatus.DRIVER_ASSIGNED,
        source="delivery-worker",
        reason=f"Driver {driver_name} assigned",
        event_id=envelope.get("event_id"),
    )
    child = build_event(
        event_type="order.driver.assigned",
        order_id=order.id,
        order_version=order.version,
        correlation_id=envelope.get("correlation_id"),
        causation_id=envelope.get("event_id"),
        data={"driver_id": driver_id, "driver_name": driver_name, "vehicle": vehicle},
    )
    enqueue_event(
        db,
        event=child,
        routing_key="order.driver.assigned",
        order_version=order.version,
    )
    return "applied"


def _delivery_exhausted(
    db: Session, order: Order, envelope: dict, code: str, reason: str
) -> None:
    apply_transition(
        db,
        order,
        OrderStatus.FAILED,
        source="delivery-worker",
        reason=reason,
        event_id=envelope.get("event_id"),
        failure_code=code,
        failure_message=reason,
    )
    child = build_event(
        event_type="order.failed",
        order_id=order.id,
        order_version=order.version,
        correlation_id=envelope.get("correlation_id"),
        causation_id=envelope.get("event_id"),
        data={"stage": "delivery", "failure_code": code, "reason": reason},
    )
    enqueue_event(db, event=child, routing_key="order.failed", order_version=order.version)


# --------------------------------------------------------------------------
# notification
# --------------------------------------------------------------------------

NOTIFICATION_COPY: dict[str, tuple[str, str]] = {
    "order.created": ("Order received", "We've received your order and it's queued for payment."),
    "order.paid": ("Payment successful", "Your payment was approved. The restaurant is confirming now."),
    "order.payment.failed": (
        "Payment failed",
        "We couldn't take payment for this order. Please try again.",
    ),
    "order.confirmed": ("Order confirmed", "The restaurant has accepted your order."),
    "order.driver.assigned": ("Driver on the way", "A driver has been assigned to your order."),
    "order.failed": (
        "Order could not be completed",
        "Something went wrong and this order was cancelled.",
    ),
}


def _apply_notification(
    db: Session, order: Order | None, envelope: dict, attempt: int
) -> str:
    settings = get_settings()
    if settings.notification_mode == "fail_always":
        # Notification failures never change order status.
        raise TransientProcessingError(
            "notification_persist_failed", "Could not persist notification (simulated)"
        )

    event_type = envelope["event_type"]
    if event_type not in NOTIFICATION_COPY:
        # Valid future event type we intentionally ignore: acknowledge it.
        LOGGER.info(
            "ignoring unsupported event_type=%s event_id=%s order_id=%s",
            event_type,
            envelope.get("event_id"),
            envelope.get("order_id"),
        )
        return "ignored"

    if order is None:
        raise TransientProcessingError("missing_order", "Order reference missing")

    title, body = NOTIFICATION_COPY[event_type]
    exists = (
        db.query(Notification)
        .filter_by(customer_id=order.customer_id, event_id=envelope["event_id"])
        .first()
    )
    if exists is not None:
        return "noop"

    db.add(
        Notification(
            id=new_notification_id(),
            customer_id=order.customer_id,
            order_id=order.id,
            event_id=envelope["event_id"],
            event_type=event_type,
            title=title,
            body=body,
        )
    )
    return "applied"


# --------------------------------------------------------------------------
# spec wiring
# --------------------------------------------------------------------------

async def _sleep_ms(delay_ms: int) -> None:
    if delay_ms > 0:
        await asyncio.sleep(delay_ms / 1000)


PAYMENT = StageHandler(
    consumer_name="payment",
    queue="payment.queue",
    expected=OrderStatus.PENDING,
    delay_ms=get_settings().payment_delay_ms,
    apply=lambda db, order, env, attempt: _apply_payment(db, order, env, attempt),
    on_exhausted=_payment_exhausted,
)

RESTAURANT = StageHandler(
    consumer_name="restaurant",
    queue="restaurant.queue",
    expected=OrderStatus.PAID,
    delay_ms=get_settings().restaurant_delay_ms,
    apply=lambda db, order, env, attempt: _apply_restaurant(db, order, env, attempt),
    on_exhausted=_restaurant_exhausted,
)

DELIVERY = StageHandler(
    consumer_name="delivery",
    queue="delivery.queue",
    expected=OrderStatus.CONFIRMED,
    delay_ms=get_settings().delivery_delay_ms,
    apply=lambda db, order, env, attempt: _apply_delivery(db, order, env, attempt),
    on_exhausted=_delivery_exhausted,
)

NOTIFICATION = StageHandler(
    consumer_name="notification",
    queue="notification.queue",
    expected=None,  # notifications never drive order state
    delay_ms=get_settings().notification_delay_ms,
    apply=lambda db, order, env, attempt: _apply_notification(db, order, env, attempt),
    on_exhausted=None,  # quarantined without touching the order
)
