"""Restaurant and menu response schemas."""

from __future__ import annotations

import datetime as dt

from pydantic import BaseModel, Field


class RestaurantOut(BaseModel):
    id: str
    name: str
    description: str
    cuisine: str
    currency: str
    image_url: str | None = None
    is_open: bool
    rating: int = Field(ge=1, le=5)
    eta_minutes: int = Field(ge=0)

    model_config = {"from_attributes": True}


class MenuItemOut(BaseModel):
    id: str
    restaurant_id: str
    name: str
    description: str
    category: str
    # Authoritative server price in integer minor units (1250 == INR 12.50).
    price_minor: int = Field(gt=0)
    currency: str
    is_available: bool
    # Image reference: absolute http(s) URL or a bundled asset path.
    image_url: str | None = None

    model_config = {"from_attributes": True}


class MenuItemWithRestaurantOut(MenuItemOut):
    """Menu item enriched with its parent restaurant (global catalogue)."""

    restaurant_name: str = ""
    restaurant_cuisine: str = ""
    restaurant_is_open: bool = True


class CategoryOut(BaseModel):
    """A distinct menu category with how many available items it holds."""

    name: str
    item_count: int = Field(ge=0)


class RestaurantDetailOut(RestaurantOut):
    menu: list[MenuItemOut] = Field(default_factory=list)
