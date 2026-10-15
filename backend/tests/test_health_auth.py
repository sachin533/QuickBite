"""Milestone 1 smoke tests: health probes, authentication, and error envelope.

These run against the real PostgreSQL instance from compose/infra (mocks
cannot demonstrate contract behavior).
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.main import app

CUSTOMER = {"email": "maya@quickbite.dev", "password": "demo12345"}
ADMIN = {"email": "admin@quickbite.dev", "password": "admin12345"}


@pytest.fixture()
def client() -> TestClient:
    with TestClient(app) as test_client:
        yield test_client


def login(client: TestClient, credentials: dict) -> dict:
    response = client.post("/api/v1/auth/login", json=credentials)
    assert response.status_code == 200, response.text
    return response.json()


class TestHealth:
    def test_live_returns_200_without_dependencies(self, client: TestClient) -> None:
        response = client.get("/health/live")
        assert response.status_code == 200
        assert response.json() == {"status": "alive"}

    def test_ready_reports_database_and_broker(self, client: TestClient) -> None:
        response = client.get("/health/ready")
        assert response.status_code in (200, 503)
        checks = response.json()["checks"]
        assert checks["database"]["required"] is True
        assert checks["broker"]["required"] is False


class TestLogin:
    def test_customer_login_returns_token_and_role(self, client: TestClient) -> None:
        payload = login(client, CUSTOMER)
        assert payload["role"] == "customer"
        assert payload["token_type"] == "bearer"
        assert payload["expires_in"] > 0
        assert payload["user"]["email"] == CUSTOMER["email"]
        assert payload["access_token"]

    def test_admin_login_returns_admin_role(self, client: TestClient) -> None:
        assert login(client, ADMIN)["role"] == "admin"

    def test_wrong_password_is_generic_401(self, client: TestClient) -> None:
        response = client.post(
            "/api/v1/auth/login",
            json={"email": CUSTOMER["email"], "password": "wrong-password"},
        )
        assert response.status_code == 401
        body = response.json()
        assert body["code"] == "invalid_credentials"
        assert body["message"] == "Incorrect email or password"
        assert body["request_id"].startswith("req_")

    def test_unknown_email_indistinguishable_from_bad_password(
        self, client: TestClient
    ) -> None:
        response = client.post(
            "/api/v1/auth/login",
            json={"email": "nobody@quickbite.dev", "password": "whatever"},
        )
        assert response.status_code == 401
        assert response.json()["code"] == "invalid_credentials"

    def test_malformed_payload_is_422_with_error_envelope(
        self, client: TestClient
    ) -> None:
        response = client.post("/api/v1/auth/login", json={"email": "not-an-email"})
        assert response.status_code == 422
        body = response.json()
        assert body["code"] == "validation_error"
        assert isinstance(body["details"], list)
        assert body["request_id"].startswith("req_")


class TestMe:
    def test_valid_token_returns_profile(self, client: TestClient) -> None:
        token = login(client, CUSTOMER)["access_token"]
        response = client.get("/api/v1/me", headers={"Authorization": f"Bearer {token}"})
        assert response.status_code == 200
        body = response.json()
        assert body["role"] == "customer"
        assert body["email"] == CUSTOMER["email"]

    def test_missing_token_is_401(self, client: TestClient) -> None:
        response = client.get("/api/v1/me")
        assert response.status_code == 401
        assert response.json()["code"] == "unauthenticated"
        assert response.headers.get("www-Authenticate") == "Bearer"

    def test_garbage_token_is_401(self, client: TestClient) -> None:
        response = client.get(
            "/api/v1/me", headers={"Authorization": "Bearer not.a.token"}
        )
        assert response.status_code == 401
        assert response.json()["code"] == "token_expired_or_invalid"

    def test_every_response_carries_request_id_header(
        self, client: TestClient
    ) -> None:
        response = client.get("/health/live")
        assert response.headers.get("x-request-id", "").startswith("req_")
