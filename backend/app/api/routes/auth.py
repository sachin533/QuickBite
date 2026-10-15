"""Authentication routes: POST /api/v1/auth/login and GET /api/v1/me."""

from __future__ import annotations

from fastapi import APIRouter, status

from app.api.deps import CurrentUser, DbSession
from app.api.errors import APIError
from app.config import get_settings
from app.domain.enums import UserRole
from app.models import User
from app.schemas.auth import LoginRequest, TokenResponse, UserSummary
from app.security import create_access_token, verify_password

router = APIRouter(prefix="/api/v1", tags=["auth"])


@router.post(
    "/auth/login",
    response_model=TokenResponse,
    status_code=status.HTTP_200_OK,
    summary="Exchange email/password for a short-lived access token",
)
def login(body: LoginRequest, db: DbSession) -> TokenResponse:
    settings = get_settings()

    # Generic message: never reveal whether the address exists.
    invalid = APIError(
        401, "invalid_credentials", "Incorrect email or password"
    )

    user = (
        db.query(User)
        .filter(User.email == body.email.lower().strip())
        .one_or_none()
    )
    if user is None or not user.is_active:
        raise invalid
    if not verify_password(body.password, user.password_hash):
        raise invalid

    token, expires_at = create_access_token(user_id=user.id, role=user.role)
    return TokenResponse(
        access_token=token,
        expires_in=settings.jwt_expires_minutes * 60,
        expires_at=expires_at,
        role=user.role,
        user=UserSummary.model_validate(user),
    )


@router.get(
    "/me",
    response_model=UserSummary,
    summary="Return the signed-in user's profile and role",
)
def me(user: CurrentUser) -> UserSummary:
    return UserSummary(
        id=user.id,
        email=user.email,
        full_name=user.full_name,
        role=user.role or UserRole.CUSTOMER.value,
    )
