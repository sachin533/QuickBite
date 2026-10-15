"""SQLAlchemy models for the QuickBite domain.

PostgreSQL is the authoritative source of order state. Every table uses UTC
timestamps, opaque prefixed identifiers, and integer minor units for money.

Tables
------
users, restaurants, menu_items, orders, order_items, order_status_history,
simulated_payments, driver_assignments, notifications, processed_events,
outbox_events, retry_jobs, quarantine_records, idempotency_keys
"""

from __future__ import annotations

import datetime as dt
from typing import Any

from sqlalchemy import (
    JSON,
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.domain.enums import (
    ORDER_STATUSES,
    OrderStatus,
    OutboxState,
    PaymentStatus,
    RetryJobStatus,
    UserRole,
)

# JSONB on PostgreSQL, generic JSON elsewhere (unit tests only).
JSON_TYPE = JSON().with_variant(JSONB(), "postgresql")

UTC = dt.timezone.utc


def utcnow() -> dt.datetime:
    return dt.datetime.now(UTC)


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    email: Mapped[str] = mapped_column(String(255), nullable=False, unique=True)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    full_name: Mapped[str] = mapped_column(String(120), nullable=False)
    role: Mapped[str] = mapped_column(
        String(20), nullable=False, default=UserRole.CUSTOMER.value
    )
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    __table_args__ = (
        CheckConstraint("role IN ('customer','admin')", name="ck_users_role"),
    )

    orders: Mapped[list["Order"]] = relationship(back_populates="customer")


class Restaurant(Base):
    __tablename__ = "restaurants"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    description: Mapped[str] = mapped_column(Text, nullable=False, default="")
    cuisine: Mapped[str] = mapped_column(String(60), nullable=False, default="")
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="INR")
    image_url: Mapped[str | None] = mapped_column(String(500), nullable=True)
    is_open: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    rating: Mapped[int] = mapped_column(Integer, nullable=False, default=5)
    eta_minutes: Mapped[int] = mapped_column(Integer, nullable=False, default=30)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    menu_items: Mapped[list["MenuItem"]] = relationship(
        back_populates="restaurant", cascade="all, delete-orphan"
    )


class MenuItem(Base):
    __tablename__ = "menu_items"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    restaurant_id: Mapped[str] = mapped_column(
        String(40), ForeignKey("restaurants.id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    description: Mapped[str] = mapped_column(Text, nullable=False, default="")
    category: Mapped[str] = mapped_column(String(60), nullable=False, default="Main")
    price_minor: Mapped[int] = mapped_column(Integer, nullable=False)
    is_available: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    restaurant: Mapped[Restaurant] = relationship(back_populates="menu_items")

    __table_args__ = (
        CheckConstraint("price_minor > 0", name="ck_menu_items_price_positive"),
        Index("ix_menu_items_restaurant", "restaurant_id", "sort_order"),
    )


class Order(Base):
    __tablename__ = "orders"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    customer_id: Mapped[str] = mapped_column(
        String(40), ForeignKey("users.id"), nullable=False
    )
    restaurant_id: Mapped[str] = mapped_column(
        String(40), ForeignKey("restaurants.id"), nullable=False
    )
    delivery_address: Mapped[str] = mapped_column(Text, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="INR")
    total_amount_minor: Mapped[int] = mapped_column(Integer, nullable=False)
    status: Mapped[str] = mapped_column(
        String(24), nullable=False, default=OrderStatus.PENDING.value
    )
    # Optimistic concurrency token: bumped on every committed transition.
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    failure_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    failure_message: Mapped[str | None] = mapped_column(Text, nullable=True)
    driver_id: Mapped[str | None] = mapped_column(String(40), nullable=True)
    correlation_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    updated_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )

    customer: Mapped[User] = relationship(back_populates="orders")
    items: Mapped[list["OrderItem"]] = relationship(
        back_populates="order", cascade="all, delete-orphan"
    )
    history: Mapped[list["OrderStatusHistory"]] = relationship(
        back_populates="order", cascade="all, delete-orphan", order_by="OrderStatusHistory.version"
    )

    __table_args__ = (
        CheckConstraint(
            "status IN ('PENDING','PAID','CONFIRMED','DRIVER_ASSIGNED',"
            "'PAYMENT_FAILED','FAILED')",
            name="ck_orders_status",
        ),
        CheckConstraint("version >= 1", name="ck_orders_version"),
        CheckConstraint("total_amount_minor >= 0", name="ck_orders_total"),
        Index("ix_orders_customer_created", "customer_id", "created_at"),
        Index("ix_orders_status", "status"),
        Index("ix_orders_restaurant", "restaurant_id"),
    )


class OrderItem(Base):
    __tablename__ = "order_items"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    order_id: Mapped[str] = mapped_column(
        String(40), ForeignKey("orders.id", ondelete="CASCADE"), nullable=False
    )
    menu_item_id: Mapped[str] = mapped_column(String(40), nullable=False)
    # Snapshot of the authoritative menu row at checkout time.
    item_name: Mapped[str] = mapped_column(String(120), nullable=False)
    quantity: Mapped[int] = mapped_column(Integer, nullable=False)
    unit_price_minor: Mapped[int] = mapped_column(Integer, nullable=False)
    line_total_minor: Mapped[int] = mapped_column(Integer, nullable=False)

    order: Mapped[Order] = relationship(back_populates="items")

    __table_args__ = (
        CheckConstraint("quantity BETWEEN 1 AND 20", name="ck_order_items_quantity"),
        CheckConstraint("unit_price_minor > 0", name="ck_order_items_price"),
        UniqueConstraint("order_id", "menu_item_id", name="uq_order_items_menu"),
    )


class OrderStatusHistory(Base):
    """Append-only transition log. One row per committed state change."""

    __tablename__ = "order_status_history"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    order_id: Mapped[str] = mapped_column(
        String(40), ForeignKey("orders.id", ondelete="CASCADE"), nullable=False
    )
    from_status: Mapped[str | None] = mapped_column(String(24), nullable=True)
    to_status: Mapped[str] = mapped_column(String(24), nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    source: Mapped[str] = mapped_column(String(32), nullable=False, default="api")
    reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    event_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    order: Mapped[Order] = relationship(back_populates="history")

    __table_args__ = (
        UniqueConstraint("order_id", "version", name="uq_history_order_version"),
        Index("ix_history_order_created", "order_id", "created_at"),
    )


class SimulatedPayment(Base):
    """At most one payment row per order (database-enforced)."""

    __tablename__ = "simulated_payments"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    order_id: Mapped[str] = mapped_column(
        String(40), ForeignKey("orders.id", ondelete="CASCADE"), nullable=False, unique=True
    )
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    amount_minor: Mapped[int] = mapped_column(Integer, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="INR")
    provider_ref: Mapped[str] = mapped_column(String(64), nullable=False)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    failure_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    __table_args__ = (
        CheckConstraint(
            "status IN ('SUCCEEDED','FAILED')", name="ck_payments_status"
        ),
    )


class DriverAssignment(Base):
    """At most one driver assignment per order (database-enforced)."""

    __tablename__ = "driver_assignments"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    order_id: Mapped[str] = mapped_column(
        String(40), ForeignKey("orders.id", ondelete="CASCADE"), nullable=False, unique=True
    )
    driver_id: Mapped[str] = mapped_column(String(40), nullable=False)
    driver_name: Mapped[str] = mapped_column(String(120), nullable=False)
    vehicle: Mapped[str] = mapped_column(String(40), nullable=False, default="Bike")
    assigned_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class Notification(Base):
    """Persisted in PostgreSQL; read through the API. Unique per (customer, event)."""

    __tablename__ = "notifications"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    customer_id: Mapped[str] = mapped_column(
        String(40), ForeignKey("users.id"), nullable=False
    )
    order_id: Mapped[str | None] = mapped_column(String(40), nullable=True)
    event_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    event_type: Mapped[str] = mapped_column(String(64), nullable=False)
    title: Mapped[str] = mapped_column(String(160), nullable=False)
    body: Mapped[str] = mapped_column(Text, nullable=False)
    is_read: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    __table_args__ = (
        UniqueConstraint("customer_id", "event_id", name="uq_notifications_customer_event"),
        Index("ix_notifications_customer_created", "customer_id", "created_at"),
    )


class ProcessedEvent(Base):
    """Deduplication ledger: one row per (consumer_name, event_id).

    ``consumer_name`` is the logical worker type (payment/restaurant/...),
    not a process instance, so scaled replicas share the same key.
    """

    __tablename__ = "processed_events"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    consumer_name: Mapped[str] = mapped_column(String(32), nullable=False)
    event_id: Mapped[str] = mapped_column(String(64), nullable=False)
    event_type: Mapped[str] = mapped_column(String(64), nullable=False)
    order_id: Mapped[str | None] = mapped_column(String(40), nullable=True)
    result: Mapped[str] = mapped_column(String(32), nullable=False, default="applied")
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    processed_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    __table_args__ = (
        UniqueConstraint("consumer_name", "event_id", name="uq_processed_consumer_event"),
        Index("ix_processed_events_order", "order_id"),
    )


class OutboxEvent(Base):
    """Transactional outbox: the exact outgoing envelope + routing destination.

    Written in the same transaction as the domain change, published later by
    the dispatcher with publisher confirms and mandatory routing.

    The row's own ``id`` is the unique *publication* identity. ``event_id``
    is NOT unique here: a delayed retry republishes the same domain event
    (same immutable event_id) as a second publication record — retry
    attempts are delivery metadata, never a new event identity.
    """

    __tablename__ = "outbox_events"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    event_id: Mapped[str] = mapped_column(String(64), nullable=False)
    schema_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    event_type: Mapped[str] = mapped_column(String(64), nullable=False)
    order_id: Mapped[str | None] = mapped_column(String(40), nullable=True)
    order_version: Mapped[int | None] = mapped_column(Integer, nullable=True)
    correlation_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    causation_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    exchange: Mapped[str] = mapped_column(String(80), nullable=False, default="quickbite.orders")
    routing_key: Mapped[str] = mapped_column(String(80), nullable=False)
    # Target queue for retries routed through the default exchange ("" -> queue).
    target_queue: Mapped[str | None] = mapped_column(String(80), nullable=True)
    # Delivery metadata for retries: exposed to consumers as the x-attempt
    # AMQP header. Never part of the immutable event payload.
    retry_attempt: Mapped[int | None] = mapped_column(Integer, nullable=True)
    payload: Mapped[dict[str, Any]] = mapped_column(JSON_TYPE, nullable=False)
    state: Mapped[str] = mapped_column(
        String(16), nullable=False, default=OutboxState.PENDING.value
    )
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    available_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )
    published_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    last_error: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    __table_args__ = (
        CheckConstraint(
            "state IN ('PENDING','SCHEDULED','SENDING','SENT','FAILED')",
            name="ck_outbox_state",
        ),
        # Dispatcher lease: claim only due, unsent records.
        Index("ix_outbox_dispatch", "state", "available_at"),
        Index("ix_outbox_order", "order_id"),
        # Same event may be published more than once (at-least-once + retries).
        Index("ix_outbox_event_id", "event_id"),
    )


class RetryJob(Base):
    """Bounded retry bookkeeping written by workers on transient failure.

    Unique (consumer_name, event_id, attempt) prevents duplicate retry jobs
    when the same delivery fails more than once.
    """

    __tablename__ = "retry_jobs"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    consumer_name: Mapped[str] = mapped_column(String(32), nullable=False)
    event_id: Mapped[str] = mapped_column(String(64), nullable=False)
    event_type: Mapped[str] = mapped_column(String(64), nullable=False)
    order_id: Mapped[str | None] = mapped_column(String(40), nullable=True)
    attempt: Mapped[int] = mapped_column(Integer, nullable=False)
    max_attempts: Mapped[int] = mapped_column(Integer, nullable=False)
    failure_code: Mapped[str] = mapped_column(String(64), nullable=False)
    failure_reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    status: Mapped[str] = mapped_column(
        String(16), nullable=False, default=RetryJobStatus.PENDING.value
    )
    scheduled_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    __table_args__ = (
        UniqueConstraint(
            "consumer_name", "event_id", "attempt", name="uq_retry_consumer_event_attempt"
        ),
        CheckConstraint("attempt >= 1", name="ck_retry_attempt"),
        CheckConstraint(
            "status IN ('PENDING','PUBLISHED','CANCELLED')", name="ck_retry_status"
        ),
        Index("ix_retry_due", "status", "scheduled_at"),
    )


class QuarantineRecord(Base):
    """Dead-letter ledger for events that exhausted retries or were malformed.

    Inspectable through the RabbitMQ management UI (quickbite.dead) and via
    the admin summary / inspection scripts.
    """

    __tablename__ = "quarantine_records"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    event_id: Mapped[str] = mapped_column(String(64), nullable=False)
    event_type: Mapped[str | None] = mapped_column(String(64), nullable=True)
    order_id: Mapped[str | None] = mapped_column(String(40), nullable=True)
    consumer_name: Mapped[str] = mapped_column(String(32), nullable=False)
    source_queue: Mapped[str] = mapped_column(String(80), nullable=False)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    failure_code: Mapped[str] = mapped_column(String(64), nullable=False)
    failure_reason: Mapped[str] = mapped_column(Text, nullable=False)
    envelope: Mapped[dict[str, Any]] = mapped_column(JSON_TYPE, nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="OPEN")
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    __table_args__ = (
        # One logical quarantine entry per consumer/event.
        UniqueConstraint("consumer_name", "event_id", name="uq_quarantine_consumer_event"),
        CheckConstraint("status IN ('OPEN','REPLAYED','DISMISSED')", name="ck_quarantine_status"),
        Index("ix_quarantine_created", "created_at"),
    )


class IdempotencyKey(Base):
    """Checkout idempotency scoped to the authenticated customer.

    The canonical request hash is unique per (customer, key): the same key
    with the same payload replays the stored response, a different payload
    is a 409 conflict.
    """

    __tablename__ = "idempotency_keys"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    customer_id: Mapped[str] = mapped_column(
        String(40), ForeignKey("users.id"), nullable=False
    )
    idempotency_key: Mapped[str] = mapped_column(String(64), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    order_id: Mapped[str] = mapped_column(
        String(40), ForeignKey("orders.id"), nullable=False
    )
    response_status: Mapped[int] = mapped_column(Integer, nullable=False, default=202)
    response_body: Mapped[dict[str, Any]] = mapped_column(JSON_TYPE, nullable=False)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    __table_args__ = (
        UniqueConstraint(
            "customer_id", "idempotency_key", name="uq_idempotency_customer_key"
        ),
    )
