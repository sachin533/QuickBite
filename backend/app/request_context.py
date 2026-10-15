"""Request-id context.

The middleware assigns ``request.state.request_id`` (or trusts a caller's
``X-Request-ID``) and exposes it to any module through a contextvar, so error
envelopes can embed it without threading the ``Request`` object everywhere.
"""

from __future__ import annotations

from contextvars import ContextVar

_request_id: ContextVar[str] = ContextVar("request_id", default="req_unknown")


def set_request_id(value: str) -> None:
    _request_id.set(value)


def current_request_id() -> str:
    return _request_id.get()
