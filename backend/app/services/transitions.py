"""State transition helper used by workers.

Every transition happens inside the consumer's transaction with the order row
locked (``SELECT ... FOR UPDATE``), bumps ``orders.version``, and appends one
history row. No backward transitions; terminal states never move again.
"""

from __future__ import annotations

import logging

from sqlalchemy.orm import Session

from app.domain.enums import OrderStatus
from app.domain.ids import new_history_id
from app.domain.state_machine import InvalidTransition, can_transition, is_terminal
from app.models import Order, OrderStatusHistory

LOGGER = logging.getLogger("quickbite.transitions")


class StaleEvent(Exception):
    """Event arrived for an order that has already moved past it (no-op)."""


class PrerequisitePending(Exception):
    """Event arrived *before* its prerequisite state was committed.

    Signals a bounded deferred retry rather than a lost or forced transition.
    """


def expected_state(
    order: Order, expected: OrderStatus, *, allow_prerequisite_retry: bool = True
) -> None:
    """Classify the current state relative to what this event expects.

    - matches            -> proceed with the transition
    - already past it    -> raise StaleEvent (acknowledge, do nothing)
    - prerequisite lost  -> raise PrerequisitePending (deferred retry)
    """
    current = OrderStatus(order.status)
    if current == expected:
        return
    # Anything already terminal or further along is a duplicate/stale delivery.
    if can_transition(expected, current) or is_terminal(current):
        raise StaleEvent(f"order already at {current.value}, expected {expected.value}")
    # current is *behind* expected (out-of-order delivery): wait for it.
    if allow_prerequisite_retry:
        raise PrerequisitePending(
            f"order at {current.value}, waiting for {expected.value}"
        )
    raise StaleEvent(f"unexpected state {current.value} for {expected.value}")


def apply_transition(
    db: Session,
    order: Order,
    target: OrderStatus,
    *,
    source: str,
    reason: str | None = None,
    event_id: str | None = None,
    failure_code: str | None = None,
    failure_message: str | None = None,
) -> bool:
    """Move the order to ``target`` once. Returns False for a no-op.

    Raises :class:`InvalidTransition` when the state machine forbids it —
    callers treat that as a bug, not a retryable condition.
    """
    if order.status == target.value:
        return False
    if not can_transition(order.status, target.value):
        raise InvalidTransition(order.status, target)

    previous = order.status
    order.status = target.value
    order.version += 1
    if target in (OrderStatus.FAILED, OrderStatus.PAYMENT_FAILED):
        order.failure_code = failure_code
        order.failure_message = failure_message

    db.add(
        OrderStatusHistory(
            id=new_history_id(),
            order_id=order.id,
            from_status=previous,
            to_status=target.value,
            version=order.version,
            source=source,
            reason=reason,
            event_id=event_id,
        )
    )
    LOGGER.info(
        "transition order_id=%s %s -> %s version=%s source=%s",
        order.id,
        previous,
        target.value,
        order.version,
        source,
    )
    return True
