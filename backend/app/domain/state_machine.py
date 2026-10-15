"""Order state machine: the single source of truth for allowed transitions.

No backward transitions. Transient failures leave the order at its last
successful state; terminal states never move again.
"""

from __future__ import annotations

from app.domain.enums import TERMINAL_STATUSES, OrderStatus

# current -> allowed next states
ALLOWED_TRANSITIONS: dict[OrderStatus, frozenset[OrderStatus]] = {
    OrderStatus.PENDING: frozenset({OrderStatus.PAID, OrderStatus.PAYMENT_FAILED}),
    OrderStatus.PAID: frozenset({OrderStatus.CONFIRMED, OrderStatus.FAILED}),
    OrderStatus.CONFIRMED: frozenset(
        {OrderStatus.DRIVER_ASSIGNED, OrderStatus.FAILED}
    ),
    OrderStatus.DRIVER_ASSIGNED: frozenset(),
    OrderStatus.PAYMENT_FAILED: frozenset(),
    OrderStatus.FAILED: frozenset(),
}


class InvalidTransition(Exception):
    """Raised when a transition is not permitted by the state machine."""

    def __init__(self, current: OrderStatus | str, target: OrderStatus | str) -> None:
        self.current = str(current)
        self.target = str(target)
        super().__init__(
            f"Transition {self.current} -> {self.target} is not allowed"
        )


def is_terminal(status: OrderStatus | str) -> bool:
    """Terminal for known states; unknown values are *not* terminal."""
    try:
        return OrderStatus(status) in TERMINAL_STATUSES
    except ValueError:
        return False


def can_transition(current: OrderStatus | str, target: OrderStatus | str) -> bool:
    """Return True when ``current -> target`` is an allowed transition.

    Re-applying the same status (a no-op redelivery) is *not* a transition.
    """
    try:
        current_status = OrderStatus(current)
        target_status = OrderStatus(target)
    except ValueError:
        return False
    return target_status in ALLOWED_TRANSITIONS[current_status]


def assert_transition(current: OrderStatus | str, target: OrderStatus | str) -> None:
    """Raise :class:`InvalidTransition` when the transition is not allowed."""
    if not can_transition(current, target):
        raise InvalidTransition(current, target)


def next_states(current: OrderStatus | str) -> list[OrderStatus]:
    """Return the allowed successor states (useful for docs and tests)."""
    try:
        status = OrderStatus(current)
    except ValueError:
        return []
    return sorted(ALLOWED_TRANSITIONS[status], key=str)
