"""FastAPI application factory.

Wires configuration validation, CORS, request-id correlation, structured
logging, error envelopes, and every versioned router.
"""

from __future__ import annotations

import logging
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.api.errors import (
    REQUEST_ID_HEADER,
    APIError,
    api_error_handler,
    error_response,
    http_exception_handler,
    validation_exception_handler,
)
from app.api.routes import admin, auth, health, orders, restaurants
from app.config import get_settings
from app.domain.ids import new_request_id
from app.request_context import set_request_id

LOGGER = logging.getLogger("quickbite.api")


class _ContextDefaultsFilter(logging.Filter):
    """Guarantee %(service)s / %(request_id)s exist for the log format."""

    def filter(self, record: logging.LogRecord) -> bool:
        if not hasattr(record, "service"):
            record.service = "api"
        if not hasattr(record, "request_id"):
            record.request_id = "-"
        return True


def configure_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format=(
            "%(asctime)s %(levelname)s %(name)s service=%(service)s "
            "request_id=%(request_id)s %(message)s"
        ),
    )
    for handler in logging.getLogger().handlers:
        handler.addFilter(_ContextDefaultsFilter())


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    # Fail fast on bad configuration instead of at the first request.
    settings = get_settings()
    LOGGER.info(
        "starting service=%s env=%s cors=%s",
        settings.app_name,
        settings.environment,
        ",".join(settings.cors_origin_list),
    )
    yield
    LOGGER.info("shutting down service=%s", settings.app_name)


async def _unhandled_exception_handler(
    request: Request, exc: Exception
) -> JSONResponse:
    LOGGER.exception("unhandled error", exc_info=exc)
    return error_response(request, 500, "internal_error", "Internal server error")


def create_app() -> FastAPI:
    settings = get_settings()
    configure_logging(settings.log_level)

    app = FastAPI(
        title=settings.app_name,
        version="1.0.0",
        description=(
            "QuickBite order API. Synchronous work ends at the database "
            "transaction; payment, restaurant, delivery, and notification "
            "processing happens asynchronously through RabbitMQ workers."
        ),
        lifespan=lifespan,
        openapi_url="/api/v1/openapi.json",
        docs_url="/docs",
        redoc_url="/redoc",
    )

    # Explicit allowed origins; never a wildcard together with credentials.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list,
        allow_credentials=True,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        allow_headers=[
            "Authorization",
            "Content-Type",
            "Idempotency-Key",
            "X-Request-ID",
        ],
        expose_headers=["Location", "X-Request-ID"],
        max_age=600,
    )

    @app.middleware("http")
    async def request_context(request: Request, call_next):
        incoming = request.headers.get(REQUEST_ID_HEADER)
        request_id = (
            incoming if incoming and incoming.startswith("req_") else new_request_id()
        )
        request.state.request_id = request_id
        set_request_id(request_id)
        started = time.perf_counter()
        response = await call_next(request)
        elapsed_ms = (time.perf_counter() - started) * 1000
        response.headers[REQUEST_ID_HEADER] = request_id
        LOGGER.info(
            "%s %s -> %s in %.1fms",
            request.method,
            request.url.path,
            response.status_code,
            elapsed_ms,
            extra={"request_id": request_id, "service": "api"},
        )
        return response

    app.add_exception_handler(APIError, api_error_handler)
    app.add_exception_handler(StarletteHTTPException, http_exception_handler)
    app.add_exception_handler(RequestValidationError, validation_exception_handler)
    app.add_exception_handler(Exception, _unhandled_exception_handler)

    app.include_router(health.router)
    app.include_router(auth.router)
    app.include_router(restaurants.router)
    app.include_router(orders.router)
    app.include_router(admin.router)

    return app


app = create_app()
