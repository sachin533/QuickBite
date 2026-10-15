"""Pure domain tests: state machine invariants (no database required)."""

from __future__ import annotations

import pytest

from app.domain.enums import OrderStatus
from app.domain.state_machine import (
    InvalidTransition,
    assert_transition,
    can_transition,
    is_terminal,
    next_states,
)


def test_happy_path_is_allowed() -> None:
    assert can_transition(OrderStatus.PENDING, OrderStatus.PAID)
    assert can_transition(OrderStatus.PAID, OrderStatus.CONFIRMED)
    assert can_transition(OrderStatus.CONFIRMED, OrderStatus.DRIVER_ASSIGNED)


def test_terminal_failures_are_allowed() -> None:
    assert can_transition(OrderStatus.PENDING, OrderStatus.PAYMENT_FAILED)
    assert can_transition(OrderStatus.PAID, OrderStatus.FAILED)
    assert can_transition(OrderStatus.CONFIRMED, OrderStatus.FAILED)


@pytest.mark.parametrize(
    "current,target",
    [
        (OrderStatus.PAID, OrderStatus.PENDING),      # no backward transitions
        (OrderStatus.CONFIRMED, OrderStatus.PAID),
        (OrderStatus.DRIVER_ASSIGNED, OrderStatus.CONFIRMED),
        (OrderStatus.PAYMENT_FAILED, OrderStatus.PAID),
        (OrderStatus.FAILED, OrderStatus.PENDING),
        (OrderStatus.PENDING, OrderStatus.CONFIRMED),  # must go through PAID
        (OrderStatus.PENDING, OrderStatus.DRIVER_ASSIGNED),
    ],
)
def test_disallowed_transitions(current: OrderStatus, target: OrderStatus) -> None:
    assert not can_transition(current, target)
    with pytest.raises(InvalidTransition):
        assert_transition(current, target)


def test_terminal_states_have_no_successors() -> None:
    for status in (
        OrderStatus.DRIVER_ASSIGNED,
        OrderStatus.PAYMENT_FAILED,
        OrderStatus.FAILED,
    ):
        assert is_terminal(status)
        assert next_states(status) == []


def test_string_values_are_accepted() -> None:
    assert can_transition("PENDING", "PAID")
    assert not can_transition("PENDING", "NOPE")


def test_unknown_status_never_transitions() -> None:
    assert not can_transition("TELEPORTED", "PAID")
    assert not is_terminal("TELEPORTED")
