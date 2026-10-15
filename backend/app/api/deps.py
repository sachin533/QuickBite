"""API dependencies: database session, current user, and role guards."""

from __future__ import annotations

from collections.abc import Iterator
from typing import Annotated

from fastapi import Depends, Header
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.api.errors import APIError
from app.db import get_db
from app.domain.enums import UserRole
from app.models import User
from app.security import TokenError, decode_access_token

bearer_scheme = HTTPBearer(auto_error=False)

DbSession = Annotated[Session, Depends(get_db)]


def _extract_token(
    credentials: HTTPAuthorizationCredentials | None,
    authorization: str | None,
) -> str:
    if credentials is not None:
        if credentials.scheme.lower() != "bearer":
            raise APIError(
                401, "unauthenticated", "Authorization scheme must be bearer"
            )
        return credentials.credentials
    if authorization:
        scheme, _, token = authorization.partition(" ")
        if scheme.lower() == "bearer" and token:
            return token
    raise APIError(
        401,
        "unauthenticated",
        "Missing bearer token",
        headers={"WWW-Authenticate": "Bearer"},
    )


def get_current_user(
    db: DbSession,
    credentials: Annotated[
        HTTPAuthorizationCredentials | None, Depends(bearer_scheme)
    ] = None,
    authorization: Annotated[str | None, Header()] = None,
) -> User:
    """Resolve the authenticated user or raise 401.

    On token expiry the client is told to re-authenticate; protected
    background requests stop at this boundary.
    """
    token = _extract_token(credentials, authorization)
    try:
        payload = decode_access_token(token)
    except TokenError:
        raise APIError(
            401,
            "token_expired_or_invalid",
            "Access token is expired or invalid; sign in again",
            headers={"WWW-Authenticate": "Bearer"},
        )

    user = db.get(User, payload["sub"])
    if user is None or not user.is_active:
        raise APIError(401, "unauthenticated", "Account not found or disabled")
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


def get_current_admin(user: CurrentUser) -> User:
    """Role guard enforced by the backend, never by the client alone."""
    if user.role != UserRole.ADMIN.value:
        raise APIError(403, "forbidden", "Admin access required")
    return user


CurrentAdmin = Annotated[User, Depends(get_current_admin)]
