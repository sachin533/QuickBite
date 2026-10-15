"""Domain enumerations shared by the API, workers, and outbox dispatcher."""

from __future__ import annotations

from enum import StrEnum


class OrderStatus(StrEnum):
    """Canonical order state machine values.

    PENDING -> PAID -> CONFIRMED -> DRIVER_ASSIGNED
    PENDING -> PAYMENT_FAILED
    PAID    -> FAILED
    CONFIRMED -> FAILED

    DRIVER_ASSIGNED is successful completion for this assignment.
    PAYMENT_FAILED and FAILED are terminal.
    """

    PENDING = "PENDING"
    PAID = "PAID"
    CONFIRMED = "CONFIRMED"
    DRIVER_ASSIGNED = "DRIVER_ASSIGNED"
    PAYMENT_FAILED = "PAYMENT_FAILED"
    FAILED = "FAILED"


class UserRole(StrEnum):
    CUSTOMER = "customer"
    ADMIN = "admin"


class OutboxState(StrEnum):
    PENDING = "PENDING"
    # Due in the future (scheduled retries); the retry scheduler flips these
    # to PENDING when their time comes, making them eligible for publication.
    SCHEDULED = "SCHEDULED"
    SENDING = "SENDING"
    SENT = "SENT"
    FAILED = "FAILED"


class RetryJobStatus(StrEnum):
    PENDING = "PENDING"
    PUBLISHED = "PUBLISHED"
    CANCELLED = "CANCELLED"


class PaymentStatus(StrEnum):
    SUCCEEDED = "SUCCEEDED"
    FAILED = "FAILED"


# Terminal states can never transition again.
TERMINAL_STATUSES: frozenset[OrderStatus] = frozenset(
    {
        OrderStatus.DRIVER_ASSIGNED,
        OrderStatus.PAYMENT_FAILED,
        OrderStatus.FAILED,
    }
)

# All statuses persisted for the `orders.status` check constraint.
ORDER_STATUSES: tuple[str, ...] = tuple(status.value for status in OrderStatus)
