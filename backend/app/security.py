"""Password hashing and bearer-token helpers.

Passwords use bcrypt (an established password-hashing library); tokens are
short-lived signed JWTs validated on every protected request. Tokens and
passwords are never logged.
"""

from __future__ import annotations

import datetime as dt
import secrets
from typing import Any

import bcrypt
import jwt

from app.config import get_settings
from app.domain.enums import UserRole

BCRYPT_ROUNDS = 12
_TOKEN_ISSUER = "quickbite"


class TokenError(Exception):
    """Raised when a bearer token is missing, malformed, expired, or invalid."""


# --- passwords -------------------------------------------------------------

def hash_password(password: str) -> str:
    if not password:
        raise ValueError("password must not be empty")
    # bcrypt only reads the first 72 bytes; reject longer input explicitly so
    # that a silent truncation can never weaken a credential.
    if len(password.encode("utf-8")) > 72:
        raise ValueError("password must be at most 72 bytes")
    digest = bcrypt.hashpw(
        password.encode("utf-8"), bcrypt.gensalt(rounds=BCRYPT_ROUNDS)
    )
    return digest.decode("ascii")


def verify_password(password: str, password_hash: str) -> bool:
    try:
        return bcrypt.checkpw(
            password.encode("utf-8"), password_hash.encode("ascii")
        )
    except (ValueError, TypeError):
        return False


# --- tokens ----------------------------------------------------------------

def create_access_token(
    *,
    user_id: str,
    role: str | UserRole,
    expires_minutes: int | None = None,
) -> tuple[str, dt.datetime]:
    """Return ``(token, expires_at)`` for a short-lived signed access token."""
    settings = get_settings()
    now = dt.datetime.now(dt.timezone.utc)
    expires_at = now + dt.timedelta(
        minutes=expires_minutes or settings.jwt_expires_minutes
    )
    payload: dict[str, Any] = {
        "sub": user_id,
        "role": str(role),
        "iss": _TOKEN_ISSUER,
        "iat": int(now.timestamp()),
        "exp": int(expires_at.timestamp()),
        "jti": secrets.token_hex(8),
    }
    token = jwt.encode(
        payload, settings.jwt_secret, algorithm=settings.jwt_algorithm
    )
    return token, expires_at


def decode_access_token(token: str) -> dict[str, Any]:
    """Validate claims and return the decoded payload.

    Raises :class:`TokenError` for every failure mode so callers can map it
    to a 401 without leaking why (expired vs. malformed vs. bad signature).
    """
    settings = get_settings()
    try:
        payload = jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
            issuer=_TOKEN_ISSUER,
            options={"require": ["exp", "iat", "sub", "iss"]},
        )
    except jwt.ExpiredSignatureError as exc:
        raise TokenError("token expired") from exc
    except jwt.PyJWTError as exc:
        raise TokenError("invalid token") from exc

    if not payload.get("sub") or not payload.get("role"):
        raise TokenError("token missing required claims")
    return payload
