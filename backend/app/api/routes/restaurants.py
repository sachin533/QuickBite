"""Restaurant browsing: GET /api/v1/restaurants, /{id}/menu, and the
global catalogue (GET /api/v1/menu, /api/v1/menu/categories)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.api.deps import CurrentUser, DbSession
from app.api.errors import APIError
from app.models import MenuItem, Restaurant
from app.schemas.common import Page
from app.schemas.restaurant import (
    CategoryOut,
    MenuItemOut,
    MenuItemWithRestaurantOut,
    RestaurantOut,
)
from app.services.pagination import page_params


router = APIRouter(prefix="/api/v1", tags=["restaurants"])


def _count(db: Session, statement) -> int:
    """COUNT(*) for a SELECT whose ordering/limits must not leak into it."""
    return int(
        db.scalar(
            select(func.count()).select_from(statement.order_by(None).subquery())
        )
        or 0
    )


@router.get(
    "/restaurants",
    response_model=Page[RestaurantOut],
    summary="Paginated restaurant list",
)
def list_restaurants(
    db: DbSession,
    user: CurrentUser,
    paging: tuple[int, int] = Depends(page_params),
) -> Page[RestaurantOut]:
    page, page_size = paging
    statement = select(Restaurant).order_by(Restaurant.name)
    total = _count(db, statement)
    rows = db.scalars(
        statement.limit(page_size).offset((page - 1) * page_size)
    ).all()
    return Page(
        items=[RestaurantOut.model_validate(row) for row in rows],
        page=page,
        page_size=page_size,
        total=total,
    )


@router.get(
    "/restaurants/{restaurant_id}/menu",
    response_model=Page[MenuItemOut],
    summary="Paginated menu with authoritative minor-unit prices",
)
def get_menu(
    restaurant_id: str,
    db: DbSession,
    user: CurrentUser,
    paging: tuple[int, int] = Depends(page_params),
) -> Page[MenuItemOut]:
    page, page_size = paging
    restaurant = db.get(Restaurant, restaurant_id)
    if restaurant is None:
        raise APIError(404, "not_found", "Restaurant not found")

    statement = (
        select(MenuItem)
        .where(MenuItem.restaurant_id == restaurant_id)
        .order_by(MenuItem.category, MenuItem.sort_order, MenuItem.name)
    )
    total = _count(db, statement)
    rows = db.scalars(
        statement.limit(page_size).offset((page - 1) * page_size)
    ).all()

    items = [
        MenuItemOut(
            id=row.id,
            restaurant_id=row.restaurant_id,
            name=row.name,
            description=row.description,
            category=row.category,
            price_minor=row.price_minor,
            currency=restaurant.currency,
            is_available=row.is_available,
            image_url=row.image_url,
        )
        for row in rows
    ]
    return Page(items=items, page=page, page_size=page_size, total=total)


@router.get(
    "/menu",
    response_model=Page[MenuItemWithRestaurantOut],
    summary="Global catalogue with search and category filter",
)
def list_all_menu_items(
    db: DbSession,
    user: CurrentUser,
    paging: tuple[int, int] = Depends(page_params),
    q: str | None = Query(
        None, max_length=120, description="Substring match on name/description"
    ),
    category: str | None = Query(
        None, max_length=60, description="Exact menu category"
    ),
    restaurant_id: str | None = Query(None, max_length=40),
) -> Page[MenuItemWithRestaurantOut]:
    """Every menu item across every restaurant.

    Powers the home page (featured items) and the menu page (search +
    category filters) without one request per restaurant. Only *open*
    restaurants are returned, so a closed kitchen never sells through here.
    """
    page, page_size = paging
    statement = (
        select(MenuItem, Restaurant)
        .join(Restaurant, MenuItem.restaurant_id == Restaurant.id)
        .where(Restaurant.is_open.is_(True))
    )
    if q:
        needle = f"%{q.strip()}%"
        statement = statement.where(
            MenuItem.name.ilike(needle) | MenuItem.description.ilike(needle)
        )
    if category:
        statement = statement.where(MenuItem.category == category)
    if restaurant_id:
        statement = statement.where(MenuItem.restaurant_id == restaurant_id)
    statement = statement.order_by(
        Restaurant.name, MenuItem.category, MenuItem.sort_order, MenuItem.name
    )

    total = int(
        db.scalar(
            select(func.count()).select_from(statement.order_by(None).subquery())
        )
        or 0
    )
    rows = db.execute(
        statement.limit(page_size).offset((page - 1) * page_size)
    ).all()

    items = [
        MenuItemWithRestaurantOut(
            id=item.id,
            restaurant_id=item.restaurant_id,
            name=item.name,
            description=item.description,
            category=item.category,
            price_minor=item.price_minor,
            currency=restaurant.currency,
            is_available=item.is_available,
            image_url=item.image_url,
            restaurant_name=restaurant.name,
            restaurant_cuisine=restaurant.cuisine,
            restaurant_is_open=restaurant.is_open,
        )
        for item, restaurant in rows
    ]
    return Page(items=items, page=page, page_size=page_size, total=total)


@router.get(
    "/menu/categories",
    response_model=list[CategoryOut],
    summary="Distinct menu categories with available-item counts",
)
def list_menu_categories(
    db: DbSession,
    user: CurrentUser,
) -> list[CategoryOut]:
    """Category chips for the menu page, derived from real menu data."""
    rows = db.execute(
        select(MenuItem.category, func.count())
        .join(Restaurant, MenuItem.restaurant_id == Restaurant.id)
        .where(Restaurant.is_open.is_(True), MenuItem.is_available.is_(True))
        .group_by(MenuItem.category)
        .order_by(func.count().desc(), MenuItem.category)
    ).all()
    return [CategoryOut(name=name, item_count=count) for name, count in rows]
