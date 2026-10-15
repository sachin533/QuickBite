"""Restaurant browsing: GET /api/v1/restaurants and /{id}/menu."""

from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.api.deps import CurrentUser, DbSession
from app.api.errors import APIError
from app.models import MenuItem, Restaurant
from app.schemas.common import Page
from app.schemas.restaurant import MenuItemOut, RestaurantOut
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
        )
        for row in rows
    ]
    return Page(items=items, page=page, page_size=page_size, total=total)
