"""Identifier helpers.

All public identifiers are opaque prefixed strings so that logs and URLs are
self-describing (``order_9f2c...``) and so that no sequence or count is leaked.
"""

from __future__ import annotations

import uuid


def _token() -> str:
    return uuid.uuid4().hex


def new_user_id() -> str:
    return f"user_{_token()}"


def new_restaurant_id() -> str:
    return f"rest_{_token()}"


def new_menu_item_id() -> str:
    return f"item_{_token()}"


def new_order_id() -> str:
    return f"order_{_token()}"


def new_order_item_id() -> str:
    return f"oitem_{_token()}"


def new_history_id() -> str:
    return f"hist_{_token()}"


def new_payment_id() -> str:
    return f"pay_{_token()}"


def new_assignment_id() -> str:
    return f"assign_{_token()}"


def new_notification_id() -> str:
    return f"notif_{_token()}"


def new_event_id() -> str:
    """Immutable domain event identity (also used as AMQP message_id)."""
    return f"evt_{_token()}"


def new_outbox_id() -> str:
    return f"out_{_token()}"


def new_retry_job_id() -> str:
    return f"retry_{_token()}"


def new_quarantine_id() -> str:
    return f"quar_{_token()}"


def new_request_id() -> str:
    """Correlation id for a single API request/response cycle."""
    return f"req_{_token()}"
