"""Shared API schemas: pagination, errors, and common primitives."""

from __future__ import annotations

from typing import Any, Generic, TypeVar

from pydantic import BaseModel, Field

T = TypeVar("T")

# Documented limits: page starts at 1, page_size never exceeds 100.
MAX_PAGE_SIZE = 100
DEFAULT_PAGE_SIZE = 20


class Page(BaseModel, Generic[T]):
    """Uniform list envelope: items, page, page_size, total."""

    items: list[T]
    page: int = Field(ge=1)
    page_size: int = Field(ge=1, le=MAX_PAGE_SIZE)
    total: int = Field(ge=0)


class ErrorDetail(BaseModel):
    """Machine-readable detail entry inside an error envelope."""

    loc: list[str] | None = None
    msg: str | None = None
    type: str | None = None


class ErrorEnvelope(BaseModel):
    """Consistent error body for every non-2xx response."""

    code: str
    message: str
    details: list[ErrorDetail] | dict[str, Any] | None = None
    request_id: str


class OkResponse(BaseModel):
    message: str
