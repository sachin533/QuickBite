"""Checkout: validation, server-authoritative pricing, and idempotency.

Guarantees implemented here (all inside ONE database transaction):

* totals are computed from current menu data — client prices are ignored;
* items must belong to one restaurant, be available, and satisfy the
  documented limits (<= 20 distinct items, quantity 1..20, address >= 8 chars);
* order + initial history + idempotency response + outbox event commit
  together — a partial order or missing event is impossible;
* the same (customer, Idempotency-Key) replays the stored acceptance
  response; a different payload is 409; concurrent duplicates create exactly
  one order thanks to the unique constraint + transaction rollback.
"""

from __future__ import annotations

import hashlib
import json
import logging
from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.api.errors import APIError
from app.config import get_settings
from app.domain.ids import new_history_id, new_order_id, new_order_item_id
from app.domain.money import DEFAULT_CURRENCY
from app.models import (
    IdempotencyKey,
    MenuItem,
    Order,
    OrderItem,
    OrderStatusHistory,
    Restaurant,
    User,
)
from app.request_context import current_request_id
from app.schemas.order import CheckoutAccepted, CheckoutRequest
from app.services.events import build_event, enqueue_event

LOGGER = logging.getLogger("quickbite.checkout")


@dataclass(frozen=True)
class CheckoutResult:
    response: CheckoutAccepted
    replayed: bool


def canonical_request_hash(body: CheckoutRequest) -> str:
    """Stable hash of the *semantic* request (order of items does not matter)."""
    canonical = {
        "restaurant_id": body.restaurant_id,
        "delivery_address": body.delivery_address.strip(),
        "items": sorted(
            ({"menu_item_id": i.menu_item_id, "quantity": i.quantity} for i in body.items),
            key=lambda item: item["menu_item_id"],
        ),
    }
    encoded = json.dumps(canonical, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _validation_error(message: str, details: list[dict] | None = None) -> APIError:
    return APIError(422, "validation_error", message, details)


def _load_and_validate(
    db: Session, body: CheckoutRequest, customer_id: str
) -> tuple[Restaurant, list[tuple[MenuItem, int]], int]:
    """Return (restaurant, [(menu_item, quantity)], total_minor) or raise."""
    settings = get_settings()

    address = body.delivery_address.strip()
    if len(address) < settings.min_delivery_address_chars:
        raise _validation_error(
            f"delivery_address must be at least "
            f"{settings.min_delivery_address_chars} characters"
        )

    restaurant = db.get(Restaurant, body.restaurant_id)
    if restaurant is None:
        raise APIError(404, "not_found", "Restaurant not found")
    if not restaurant.is_open:
        raise _validation_error("Restaurant is not currently accepting orders")

    if len(body.items) > settings.max_distinct_items:
        raise _validation_error(
            f"An order may contain at most {settings.max_distinct_items} distinct items"
        )

    # Reject duplicates up front so the same menu item is not ordered twice.
    seen: set[str] = set()
    for item in body.items:
        if item.menu_item_id in seen:
            raise _validation_error(
                "Duplicate menu items in request", [{"menu_item_id": item.menu_item_id}]
            )
        seen.add(item.menu_item_id)
        if not (1 <= item.quantity <= settings.max_quantity_per_item):
            raise _validation_error(
                f"quantity must be between 1 and {settings.max_quantity_per_item}"
            )

    menu_rows = db.scalars(
        select(MenuItem).where(
            MenuItem.id.in_([i.menu_item_id for i in body.items])
        )
    ).all()
    by_id = {row.id: row for row in menu_rows}

    resolved: list[tuple[MenuItem, int]] = []
    details: list[dict] = []
    for item in body.items:
        menu_item = by_id.get(item.menu_item_id)
        if menu_item is None:
            details.append({"menu_item_id": item.menu_item_id, "msg": "unknown item"})
            continue
        if menu_item.restaurant_id != body.restaurant_id:
            # One order = one restaurant.
            details.append(
                {
                    "menu_item_id": item.menu_item_id,
                    "msg": f"belongs to restaurant {menu_item.restaurant_id}",
                }
            )
            continue
        if not menu_item.is_available:
            details.append({"menu_item_id": item.menu_item_id, "msg": "unavailable"})
            continue
        resolved.append((menu_item, item.quantity))

    if details:
        raise _validation_error(
            "One or more items cannot be ordered with this restaurant", details
        )

    # Server-authoritative total from *current* menu prices.
    total_minor = sum(m.price_minor * qty for m, qty in resolved)
    return restaurant, resolved, total_minor


def create_order(
    db: Session, *, user: User, body: CheckoutRequest, idempotency_key: str
) -> CheckoutResult:
    """Create (or idempotently replay) an order. Caller manages the outer
    transaction boundary via the request session commit."""
    request_hash = canonical_request_hash(body)

    # --- fast path: this key already completed for this customer ----------
    existing = db.scalar(
        select(IdempotencyKey).where(
            IdempotencyKey.customer_id == user.id,
            IdempotencyKey.idempotency_key == idempotency_key,
        )
    )
    if existing is not None:
        return _replay_or_conflict(existing, request_hash)

    restaurant, resolved, total_minor = _load_and_validate(db, body, user.id)
    settings = get_settings()
    currency = restaurant.currency or DEFAULT_CURRENCY
    correlation_id = current_request_id()
    order_id = new_order_id()

    order = Order(
        id=order_id,
        customer_id=user.id,
        restaurant_id=restaurant.id,
        delivery_address=body.delivery_address.strip(),
        currency=currency,
        total_amount_minor=total_minor,
        status="PENDING",
        version=1,
        correlation_id=correlation_id,
    )
    db.add(order)
    db.flush()  # surface FK problems before writing dependent rows

    for menu_item, quantity in resolved:
        db.add(
            OrderItem(
                id=new_order_item_id(),
                order_id=order.id,
                menu_item_id=menu_item.id,
                item_name=menu_item.name,
                quantity=quantity,
                unit_price_minor=menu_item.price_minor,
                line_total_minor=menu_item.price_minor * quantity,
            )
        )

    db.add(
        OrderStatusHistory(
            id=new_history_id(),
            order_id=order.id,
            from_status=None,
            to_status="PENDING",
            version=1,
            source="api",
            reason="Order accepted",
            event_id=None,
        )
    )

    accepted = CheckoutAccepted(
        order_id=order.id,
        status="PENDING",
        currency=currency,
        total_amount_minor=total_minor,
        version=1,
    )
    db.add(
        IdempotencyKey(
            id=f"idem_{order.id[6:]}",
            customer_id=user.id,
            idempotency_key=idempotency_key,
            request_hash=request_hash,
            order_id=order.id,
            response_status=202,
            response_body=accepted.model_dump(mode="json"),
        )
    )

    # Same transaction as the domain change: an accepted order always has its
    # event queued, even if the broker is down (the outbox just waits).
    event = build_event(
        event_type="order.created",
        order_id=order.id,
        order_version=1,
        correlation_id=correlation_id,
        data={"customer_id": user.id, "restaurant_id": restaurant.id},
    )
    enqueue_event(db, event=event, routing_key="order.created", order_version=1)

    try:
        db.commit()
    except IntegrityError:
        # A concurrent identical submission won the unique constraint race:
        # roll back *everything* (including this order) and replay theirs.
        db.rollback()
        winner = db.scalar(
            select(IdempotencyKey).where(
                IdempotencyKey.customer_id == user.id,
                IdempotencyKey.idempotency_key == idempotency_key,
            )
        )
        if winner is None:
            # Not a duplicate-key race on idempotency: the real cause wins.
            raise
        return _replay_or_conflict(winner, request_hash)

    LOGGER.info(
        "order accepted order_id=%s total_minor=%s items=%d",
        order.id,
        total_minor,
        len(resolved),
    )
    return CheckoutResult(response=accepted, replayed=False)


def _replay_or_conflict(existing: IdempotencyKey, request_hash: str) -> CheckoutResult:
    if existing.request_hash != request_hash:
        # Same key, different payload -> conflict (never a second order).
        raise APIError(
            409,
            "idempotency_key_conflict",
            "This Idempotency-Key was already used with a different payload",
        )
    body = dict(existing.response_body)
    LOGGER.info(
        "idempotent replay order_id=%s key=%s",
        existing.order_id,
        existing.idempotency_key,
    )
    return CheckoutResult(
        response=CheckoutAccepted.model_validate(body), replayed=True
    )
