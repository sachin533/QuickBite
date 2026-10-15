"""Order request/response schemas.

Money is always integer minor units computed on the server from menu data;
client-supplied prices, customer ids, and totals are never accepted.
"""

from __future__ import annotations

import datetime as dt
from typing import Any

from pydantic import BaseModel, Field


# --- checkout ---------------------------------------------------------------

class CheckoutItem(BaseModel):
    menu_item_id: str = Field(min_length=1, max_length=40)
    quantity: int = Field(ge=1, le=20)


class CheckoutRequest(BaseModel):
    restaurant_id: str = Field(min_length=1, max_length=40)
    delivery_address: str = Field(min_length=8, max_length=500)
    items: list[CheckoutItem] = Field(min_length=1, max_length=20)


class CheckoutAccepted(BaseModel):
    """202 body — also the replayed body for an idempotent retry."""

    order_id: str
    status: str
    currency: str
    total_amount_minor: int
    version: int
    message: str = "Order accepted for asynchronous processing."


# --- order reads ------------------------------------------------------------

class OrderItemOut(BaseModel):
    menu_item_id: str
    item_name: str
    quantity: int
    unit_price_minor: int
    line_total_minor: int

    model_config = {"from_attributes": True}


class OrderSummary(BaseModel):
    id: str
    restaurant_id: str
    restaurant_name: str | None = None
    status: str
    currency: str
    total_amount_minor: int
    version: int
    failure_code: str | None = None
    created_at: dt.datetime
    updated_at: dt.datetime

    model_config = {"from_attributes": True}


class OrderDetail(OrderSummary):
    customer_id: str
    delivery_address: str
    driver_id: str | None = None
    items: list[OrderItemOut] = Field(default_factory=list)
    correlation_id: str | None = None


class HistoryEntry(BaseModel):
    id: str
    from_status: str | None = None
    to_status: str
    version: int
    source: str
    reason: str | None = None
    created_at: dt.datetime

    model_config = {"from_attributes": True}


class NotificationOut(BaseModel):
    id: str
    order_id: str | None
    event_type: str
    title: str
    body: str
    is_read: bool
    created_at: dt.datetime

    model_config = {"from_attributes": True}


# --- admin ------------------------------------------------------------------

class AdminOrderOut(OrderSummary):
    customer_email: str | None = None


class AdminSummaryOut(BaseModel):
    orders_by_status: dict[str, int]
    total_orders: int
    pending_outbox: int
    pending_retries: int
    open_quarantine: int
