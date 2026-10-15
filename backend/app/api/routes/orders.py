"""Order routes: checkout (idempotent) and customer-facing reads.

POST /api/v1/orders              202 + Location, Idempotency-Key required
GET  /api/v1/orders              paginated, own orders, optional status filter
GET  /api/v1/orders/{id}         owner or admin
GET  /api/v1/orders/{id}/history           owner or admin
GET  /api/v1/orders/{id}/notifications     owner or admin, paginated
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Header, Query, Response
from sqlalchemy import func, select

from app.api.deps import CurrentUser, DbSession
from app.api.errors import APIError
from app.domain.enums import ORDER_STATUSES, UserRole
from app.models import (
    Notification,
    Order,
    OrderItem,
    OrderStatusHistory,
    Restaurant,
    User,
)
from app.schemas.common import Page
from app.schemas.order import (
    CheckoutAccepted,
    CheckoutRequest,
    HistoryEntry,
    NotificationOut,
    OrderDetail,
    OrderItemOut,
    OrderSummary,
)
from app.services.checkout import create_order
from app.services.pagination import page_params

router = APIRouter(prefix="/api/v1", tags=["orders"])

IDEMPOTENCY_HEADER = "Idempotency-Key"

_STATUS_PATTERN = "^(" + "|".join(ORDER_STATUSES) + ")$"


def _load_owned_order(db, order_id: str, user: User) -> Order:
    """404 for unknown *and* other customers' orders (no existence leak)."""
    order = db.get(Order, order_id)
    if order is None:
        raise APIError(404, "not_found", "Order not found")
    if order.customer_id != user.id and user.role != UserRole.ADMIN.value:
        raise APIError(404, "not_found", "Order not found")
    return order


@router.post(
    "/orders",
    response_model=CheckoutAccepted,
    status_code=202,
    summary="Place an order (idempotent, asynchronous processing)",
)
def post_order(
    body: CheckoutRequest,
    db: DbSession,
    user: CurrentUser,
    response: Response,
    idempotency_key: Annotated[str | None, Header(alias=IDEMPOTENCY_HEADER)] = None,
) -> CheckoutAccepted:
    if not idempotency_key or not idempotency_key.strip():
        raise APIError(
            422,
            "validation_error",
            "Idempotency-Key header is required",
            [{"loc": ["header", "Idempotency-Key"], "msg": "required"}],
        )
    key = idempotency_key.strip()
    if len(key) > 64 or not all(c.isalnum() or c in "-_" for c in key):
        raise APIError(
            422,
            "validation_error",
            "Idempotency-Key must be 1-64 characters of [A-Za-z0-9_-]",
            [{"loc": ["header", "Idempotency-Key"], "msg": "invalid format"}],
        )
    if user.role == UserRole.ADMIN.value:
        raise APIError(403, "forbidden", "Admin accounts cannot place orders")

    result = create_order(db, user=user, body=body, idempotency_key=key)
    # Same Location for the original and every replay of that key.
    response.headers["Location"] = f"/api/v1/orders/{result.response.order_id}"
    response.headers["X-Idempotent-Replay"] = "true" if result.replayed else "false"
    response.status_code = 202
    return result.response


@router.get(
    "/orders",
    response_model=Page[OrderSummary],
    summary="Paginated list of the current user's orders",
)
def list_orders(
    db: DbSession,
    user: CurrentUser,
    paging: tuple[int, int] = Depends(page_params),
    status: str | None = Query(
        None,
        description="Optional status filter",
        pattern=_STATUS_PATTERN,
    ),
) -> Page[OrderSummary]:
    page, page_size = paging
    statement = (
        select(Order)
        .where(Order.customer_id == user.id)
        .order_by(Order.created_at.desc(), Order.id.desc())
    )
    count_statement = select(func.count()).select_from(Order).where(
        Order.customer_id == user.id
    )
    if status:
        statement = statement.where(Order.status == status)
        count_statement = count_statement.where(Order.status == status)

    total = int(db.scalar(count_statement) or 0)
    rows = db.scalars(
        statement.limit(page_size).offset((page - 1) * page_size)
    ).all()

    names = _restaurant_names(db, [row.restaurant_id for row in rows])
    items = [_summary(row, names) for row in rows]
    return Page(items=items, page=page, page_size=page_size, total=total)


def _restaurant_names(db, restaurant_ids: list[str]) -> dict[str, str]:
    unique = set(restaurant_ids)
    if not unique:
        return {}
    rows = db.execute(
        select(Restaurant.id, Restaurant.name).where(Restaurant.id.in_(unique))
    ).all()
    return {rid: name for rid, name in rows}


def _summary(order: Order, names: dict[str, str]) -> OrderSummary:
    return OrderSummary(
        id=order.id,
        restaurant_id=order.restaurant_id,
        restaurant_name=names.get(order.restaurant_id),
        status=order.status,
        currency=order.currency,
        total_amount_minor=order.total_amount_minor,
        version=order.version,
        failure_code=order.failure_code,
        created_at=order.created_at,
        updated_at=order.updated_at,
    )


@router.get(
    "/orders/{order_id}",
    response_model=OrderDetail,
    summary="Order detail with items, totals, failure info, and version",
)
def get_order(order_id: str, db: DbSession, user: CurrentUser) -> OrderDetail:
    order = _load_owned_order(db, order_id, user)
    items = db.scalars(
        select(OrderItem).where(OrderItem.order_id == order.id).order_by(OrderItem.item_name)
    ).all()
    names = _restaurant_names(db, [order.restaurant_id])
    return OrderDetail(
        **_summary(order, names).model_dump(),
        customer_id=order.customer_id,
        delivery_address=order.delivery_address,
        driver_id=order.driver_id,
        correlation_id=order.correlation_id,
        items=[OrderItemOut.model_validate(item) for item in items],
    )


@router.get(
    "/orders/{order_id}/history",
    response_model=Page[HistoryEntry],
    summary="Append-only state-transition timeline",
)
def get_history(
    order_id: str,
    db: DbSession,
    user: CurrentUser,
    paging: tuple[int, int] = Depends(page_params),
) -> Page[HistoryEntry]:
    page, page_size = paging
    _load_owned_order(db, order_id, user)
    statement = (
        select(OrderStatusHistory)
        .where(OrderStatusHistory.order_id == order_id)
        .order_by(OrderStatusHistory.version)
    )
    total = int(
        db.scalar(
            select(func.count())
            .select_from(OrderStatusHistory)
            .where(OrderStatusHistory.order_id == order_id)
        )
        or 0
    )
    rows = db.scalars(
        statement.limit(page_size).offset((page - 1) * page_size)
    ).all()
    return Page(
        items=[HistoryEntry.model_validate(row) for row in rows],
        page=page,
        page_size=page_size,
        total=total,
    )


@router.get(
    "/orders/{order_id}/notifications",
    response_model=Page[NotificationOut],
    summary="Persisted notification feed for an order",
)
def get_order_notifications(
    order_id: str,
    db: DbSession,
    user: CurrentUser,
    paging: tuple[int, int] = Depends(page_params),
) -> Page[NotificationOut]:
    page, page_size = paging
    _load_owned_order(db, order_id, user)
    statement = (
        select(Notification)
        .where(Notification.order_id == order_id, Notification.customer_id == user.id)
        .order_by(Notification.created_at.desc(), Notification.id.desc())
    )
    total = int(
        db.scalar(
            select(func.count())
            .select_from(Notification)
            .where(
                Notification.order_id == order_id,
                Notification.customer_id == user.id,
            )
        )
        or 0
    )
    rows = db.scalars(
        statement.limit(page_size).offset((page - 1) * page_size)
    ).all()
    return Page(
        items=[NotificationOut.model_validate(row) for row in rows],
        page=page,
        page_size=page_size,
        total=total,
    )
