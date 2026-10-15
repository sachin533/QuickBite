"""Pagination helper: one consistent page/page_size/total contract."""

from __future__ import annotations

from typing import Any, TypeVar

from fastapi import Query
from pydantic import BaseModel
from sqlalchemy import Select, func, select
from sqlalchemy.orm import Session

from app.schemas.common import DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE, Page

T = TypeVar("T")


def page_params(
    page: int = Query(1, ge=1),
    page_size: int = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE),
) -> tuple[int, int]:
    """Shared ``page`` / ``page_size`` query parameters (max 100)."""
    return page, page_size


def paginate(
    db: Session,
    statement: Select,
    *,
    page: int,
    page_size: int,
    schema: type[T],
) -> Page[T]:
    """Apply LIMIT/OFFSET plus a COUNT(*) total to a SELECT."""
    total = db.scalar(
        select(func.count()).select_from(statement.order_by(None).subquery())
    )
    rows = db.scalars(
        statement.limit(page_size).offset((page - 1) * page_size)
    ).all()
    return Page[T](
        items=[schema.model_validate(row) for row in rows],
        page=page,
        page_size=page_size,
        total=int(total or 0),
    )


def page_of_dicts(
    items: list[Any], *, page: int, page_size: int, total: int
) -> Page[Any]:
    """Build a page envelope from already-serialized items (dicts/Pydantic)."""
    return Page(items=items, page=page, page_size=page_size, total=total)
