"""Error envelope helpers.

Every non-2xx response carries the same body:

    { "code": "...", "message": "...", "details": [...], "request_id": "req_..." }

The request id is also present in structured logs and response headers
(``X-Request-ID``) so a user-visible failure can be traced end to end.
"""

from __future__ import annotations

from typing import Any

from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.request_context import current_request_id

REQUEST_ID_HEADER = "X-Request-ID"


class APIError(Exception):
    """Application error that renders as a consistent JSON envelope."""

    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        details: Any = None,
        headers: dict[str, str] | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.details = details
        self.headers = headers or {}


def request_id_of(request: Request | str | None) -> str:
    """Accept a ``Request`` (reads ``request.state``) or a plain id string."""
    if isinstance(request, str):
        return request
    if request is None:
        return current_request_id()
    return getattr(request.state, "request_id", current_request_id())


def envelope(
    request: Request | str | None, code: str, message: str, details: Any = None
) -> dict[str, Any]:
    return {
        "code": code,
        "message": message,
        "details": details,
        "request_id": request_id_of(request),
    }


def error_response(
    request: Request | str | None,
    status_code: int,
    code: str,
    message: str,
    details: Any = None,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content=envelope(request, code, message, details),
        headers=headers,
    )


# Map common HTTP exceptions onto stable machine-readable codes.
_REASONABLE_CODES = {
    400: "bad_request",
    401: "unauthenticated",
    403: "forbidden",
    404: "not_found",
    405: "method_not_allowed",
    409: "conflict",
    422: "validation_error",
    429: "rate_limited",
    500: "internal_error",
    503: "service_unavailable",
}


async def api_error_handler(request: Request, exc: APIError) -> JSONResponse:
    return error_response(
        request, exc.status_code, exc.code, exc.message, exc.details, exc.headers
    )


async def http_exception_handler(
    request: Request, exc: StarletteHTTPException
) -> JSONResponse:
    code = _REASONABLE_CODES.get(exc.status_code, f"http_{exc.status_code}")
    detail = exc.detail
    message = detail if isinstance(detail, str) else "request failed"
    details = None if isinstance(detail, str) else detail
    headers = dict(exc.headers or {})
    return error_response(
        request, exc.status_code, code, message, details, headers=headers
    )


async def validation_exception_handler(
    request: Request, exc: RequestValidationError
) -> JSONResponse:
    details = [
        {
            "loc": [str(part) for part in err.get("loc", [])],
            "msg": err.get("msg", ""),
            "type": err.get("type", ""),
        }
        for err in exc.errors()
    ]
    return error_response(
        request,
        422,
        "validation_error",
        "Request validation failed",
        details,
    )
