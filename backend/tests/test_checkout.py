"""Milestone 2 acceptance: checkout validation, idempotency, access control.

Runs against real PostgreSQL. Every test logs in through the real API.
"""

from __future__ import annotations

import concurrent.futures
import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete, func, select

from app.db import SessionLocal
from app.main import app
from app.models import (
    IdempotencyKey,
    MenuItem,
    Order,
    OrderItem,
    OrderStatusHistory,
    OutboxEvent,
    Restaurant,
)

CUSTOMER = {"email": "maya@quickbite.dev", "password": "demo12345"}
OTHER = {"email": "arjun@quickbite.dev", "password": "demo12345"}
ADMIN = {"email": "admin@quickbite.dev", "password": "admin12345"}


@pytest.fixture()
def client() -> TestClient:
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture(autouse=True)
def clean_order_tables():
    """Each test starts from an empty order/outbox state (seed data stays)."""
    with SessionLocal() as session:
        for model in (
            IdempotencyKey,
            OrderItem,
            OrderStatusHistory,
            OutboxEvent,
            Order,
        ):
            session.execute(delete(model))
        session.commit()
    yield


def _login(client: TestClient, credentials: dict) -> dict:
    response = client.post("/api/v1/auth/login", json=credentials)
    assert response.status_code == 200, response.text
    return response.json()


def _auth(client: TestClient, credentials: dict = CUSTOMER) -> dict:
    return {"Authorization": f"Bearer {_login(client, credentials)['access_token']}"}


def _menu(client: TestClient, auth: dict, restaurant_id: str) -> list[dict]:
    response = client.get(
        f"/api/v1/restaurants/{restaurant_id}/menu", headers=auth
    )
    assert response.status_code == 200, response.text
    return response.json()["items"]


def _restaurant_and_items(client: TestClient, auth: dict) -> tuple[str, list[dict]]:
    response = client.get("/api/v1/restaurants", headers=auth)
    assert response.status_code == 200, response.text
    restaurants = response.json()["items"]
    assert restaurants, "seeded restaurants required"
    rest = restaurants[0]
    items = [i for i in _menu(client, auth, rest["id"]) if i["is_available"]]
    return rest["id"], items


def _checkout_payload(restaurant_id: str, items: list[dict], qty: int = 2) -> dict:
    return {
        "restaurant_id": restaurant_id,
        "delivery_address": "12 Lake Road, Bengaluru",
        "items": [
            {"menu_item_id": items[0]["id"], "quantity": qty},
            {"menu_item_id": items[1]["id"], "quantity": 1},
        ],
    }


class TestBrowsing:
    def test_restaurants_and_menu_require_auth(self, client: TestClient) -> None:
        assert client.get("/api/v1/restaurants").status_code == 401

    def test_menu_prices_are_minor_units(self, client: TestClient) -> None:
        auth = _auth(client)
        rest_id, items = _restaurant_and_items(client, auth)
        assert items, "restaurant must expose available menu items"
        for item in items:
            assert isinstance(item["price_minor"], int)
            assert item["price_minor"] > 0
            assert item["currency"] == "INR"

    def test_pagination_bounds(self, client: TestClient) -> None:
        auth = _auth(client)
        response = client.get(
            "/api/v1/restaurants?page=1&page_size=101", headers=auth
        )
        assert response.status_code == 422  # max page_size is 100

    def test_unknown_restaurant_is_404(self, client: TestClient) -> None:
        auth = _auth(client)
        assert (
            client.get("/api/v1/restaurants/rest_nope/menu", headers=auth).status_code
            == 404
        )


class TestCheckoutValidation:
    def test_happy_path_returns_202_and_persists_outbox(
        self, client: TestClient
    ) -> None:
        auth = _auth(client)
        rest_id, items = _restaurant_and_items(client, auth)
        expected_total = items[0]["price_minor"] * 2 + items[1]["price_minor"] * 1

        response = client.post(
            "/api/v1/orders",
            headers={**auth, "Idempotency-Key": str(uuid.uuid4())},
            json=_checkout_payload(rest_id, items),
        )
        assert response.status_code == 202, response.text
        body = response.json()
        assert body["status"] == "PENDING"
        assert body["currency"] == "INR"
        # Totals come from the server menu, never from the client.
        assert body["total_amount_minor"] == expected_total
        assert body["version"] == 1
        assert response.headers["location"] == f"/api/v1/orders/{body['order_id']}"

        with SessionLocal() as session:
            order = session.get(Order, body["order_id"])
            assert order is not None and order.status == "PENDING"
            history = session.scalars(
                select(OrderStatusHistory).where(
                    OrderStatusHistory.order_id == body["order_id"]
                )
            ).all()
            assert len(history) == 1 and history[0].to_status == "PENDING"
            outbox = session.scalars(
                select(OutboxEvent).where(
                    OutboxEvent.order_id == body["order_id"]
                )
            ).all()
            assert len(outbox) == 1
            assert outbox[0].event_type == "order.created"
            assert outbox[0].routing_key == "order.created"
            assert outbox[0].exchange == "quickbite.orders"
            assert outbox[0].payload["event_id"] == outbox[0].event_id

    def test_missing_idempotency_key_is_rejected(self, client: TestClient) -> None:
        auth = _auth(client)
        rest_id, items = _restaurant_and_items(client, auth)
        response = client.post(
            "/api/v1/orders", headers=auth, json=_checkout_payload(rest_id, items)
        )
        assert response.status_code == 422
        assert "Idempotency-Key" in response.json()["message"]

    def test_mixed_restaurants_rejected(self, client: TestClient) -> None:
        auth = _auth(client)
        rest_id, items = _restaurant_and_items(client, auth)
        # A menu item from a *different* restaurant.
        response = client.get("/api/v1/restaurants", headers=auth)
        other_rest = next(
            r for r in response.json()["items"] if r["id"] != rest_id
        )
        other_items = _menu(client, auth, other_rest["id"])
        payload = _checkout_payload(rest_id, items)
        payload["items"].append(
            {"menu_item_id": other_items[0]["id"], "quantity": 1}
        )
        response = client.post(
            "/api/v1/orders",
            headers={**auth, "Idempotency-Key": str(uuid.uuid4())},
            json=payload,
        )
        assert response.status_code == 422
        body = response.json()
        assert body["code"] == "validation_error"
        assert body["details"], "must explain which item is invalid"

    def test_unavailable_item_rejected(self, client: TestClient) -> None:
        auth = _auth(client)
        # Find *any* seeded restaurant that exposes an unavailable item.
        restaurants = client.get("/api/v1/restaurants", headers=auth).json()["items"]
        target = None
        for rest in restaurants:
            items = _menu(client, auth, rest["id"])
            unavailable = next((i for i in items if not i["is_available"]), None)
            if unavailable is not None:
                target = (rest["id"], unavailable)
                break
        if target is None:
            pytest.skip("no seeded unavailable menu item anywhere")
        rest_id, unavailable = target
        payload = {
            "restaurant_id": rest_id,
            "delivery_address": "12 Lake Road, Bengaluru",
            "items": [{"menu_item_id": unavailable["id"], "quantity": 1}],
        }
        response = client.post(
            "/api/v1/orders",
            headers={**auth, "Idempotency-Key": str(uuid.uuid4())},
            json=payload,
        )
        assert response.status_code == 422
        assert any(
            d.get("menu_item_id") == unavailable["id"]
            for d in response.json()["details"] or []
        ), "must name the unavailable item"

    def test_quantity_bounds_enforced(self, client: TestClient) -> None:
        auth = _auth(client)
        rest_id, items = _restaurant_and_items(client, auth)
        payload = _checkout_payload(rest_id, items)
        payload["items"][0]["quantity"] = 21
        response = client.post(
            "/api/v1/orders",
            headers={**auth, "Idempotency-Key": str(uuid.uuid4())},
            json=payload,
        )
        assert response.status_code == 422  # schema: 1..20

    def test_short_address_rejected(self, client: TestClient) -> None:
        auth = _auth(client)
        rest_id, items = _restaurant_and_items(client, auth)
        payload = _checkout_payload(rest_id, items)
        payload["delivery_address"] = "1 Road"
        response = client.post(
            "/api/v1/orders",
            headers={**auth, "Idempotency-Key": str(uuid.uuid4())},
            json=payload,
        )
        assert response.status_code == 422

    def test_no_partial_commit_on_validation_failure(
        self, client: TestClient
    ) -> None:
        auth = _auth(client)
        rest_id, items = _restaurant_and_items(client, auth)
        before = _order_count()
        payload = _checkout_payload(rest_id, items)
        payload["items"][0]["menu_item_id"] = "item_does_not_exist"
        response = client.post(
            "/api/v1/orders",
            headers={**auth, "Idempotency-Key": str(uuid.uuid4())},
            json=payload,
        )
        assert response.status_code == 422
        assert _order_count() == before
        assert _outbox_count() == 0


def _order_count() -> int:
    with SessionLocal() as session:
        return int(session.scalar(select(func.count()).select_from(Order)) or 0)


def _outbox_count() -> int:
    with SessionLocal() as session:
        return int(session.scalar(select(func.count()).select_from(OutboxEvent)) or 0)


class TestIdempotency:
    def _post(
        self, client: TestClient, auth: dict, payload: dict, key: str
    ):
        return client.post(
            "/api/v1/orders",
            headers={**auth, "Idempotency-Key": key},
            json=payload,
        )

    def test_same_key_and_payload_returns_same_order(
        self, client: TestClient
    ) -> None:
        auth = _auth(client)
        rest_id, items = _restaurant_and_items(client, auth)
        payload = _checkout_payload(rest_id, items)
        key = str(uuid.uuid4())

        first = self._post(client, auth, payload, key)
        second = self._post(client, auth, payload, key)
        assert first.status_code == 202 and second.status_code == 202
        assert first.json() == second.json()
        assert first.headers["location"] == second.headers["location"]
        assert second.headers["x-idempotent-replay"] == "true"
        assert _order_count() == 1, "replay must not create a second order"
        assert _outbox_count() == 1, "replay must not emit a second event"

    def test_same_key_different_payload_is_409(self, client: TestClient) -> None:
        auth = _auth(client)
        rest_id, items = _restaurant_and_items(client, auth)
        key = str(uuid.uuid4())
        assert (
            self._post(client, auth, _checkout_payload(rest_id, items), key).status_code
            == 202
        )
        changed = _checkout_payload(rest_id, items, qty=3)
        conflict = self._post(client, auth, changed, key)
        assert conflict.status_code == 409
        assert conflict.json()["code"] == "idempotency_key_conflict"
        assert _order_count() == 1

    def test_key_is_scoped_per_customer(self, client: TestClient) -> None:
        """The same key from two customers yields two distinct orders."""
        maya = _auth(client, CUSTOMER)
        arjun = _auth(client, OTHER)
        rest_id, items = _restaurant_and_items(client, maya)
        payload = _checkout_payload(rest_id, items)
        key = "shared-key-123"

        first = self._post(client, maya, payload, key)
        second = self._post(client, arjun, payload, key)
        assert first.status_code == 202 and second.status_code == 202
        assert first.json()["order_id"] != second.json()["order_id"]
        assert _order_count() == 2

    def test_concurrent_identical_submissions_create_exactly_one_order(
        self, client: TestClient
    ) -> None:
        auth = _auth(client)
        rest_id, items = _restaurant_and_items(client, auth)
        payload = _checkout_payload(rest_id, items)
        key = str(uuid.uuid4())

        def submit(_: int) -> dict:
            with TestClient(app) as parallel_client:
                response = parallel_client.post(
                    "/api/v1/orders",
                    headers={**auth, "Idempotency-Key": key},
                    json=payload,
                )
                assert response.status_code in (202, 409), response.text
                return response.json()

        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
            results = list(pool.map(submit, range(5)))

        assert _order_count() == 1, "concurrent duplicates must create one order"
        order_ids = {r["order_id"] for r in results if "order_id" in r}
        assert len(order_ids) == 1, "every 202 must reference the same order"


class TestAccessControl:
    def test_customer_cannot_see_another_customers_order(
        self, client: TestClient
    ) -> None:
        maya = _auth(client, CUSTOMER)
        arjun = _auth(client, OTHER)
        rest_id, items = _restaurant_and_items(client, maya)
        order_id = client.post(
            "/api/v1/orders",
            headers={**maya, "Idempotency-Key": str(uuid.uuid4())},
            json=_checkout_payload(rest_id, items),
        ).json()["order_id"]

        assert (
            client.get(f"/api/v1/orders/{order_id}", headers=arjun).status_code
            == 404
        )
        assert (
            client.get(
                f"/api/v1/orders/{order_id}/history", headers=arjun
            ).status_code
            == 404
        )

    def test_customer_cannot_use_admin_routes(self, client: TestClient) -> None:
        maya = _auth(client, CUSTOMER)
        assert client.get("/api/v1/admin/orders", headers=maya).status_code == 403
        assert client.get("/api/v1/admin/summary", headers=maya).status_code == 403

    def test_admin_can_view_any_order(self, client: TestClient) -> None:
        maya = _auth(client, CUSTOMER)
        admin = _auth(client, ADMIN)
        rest_id, items = _restaurant_and_items(client, maya)
        order_id = client.post(
            "/api/v1/orders",
            headers={**maya, "Idempotency-Key": str(uuid.uuid4())},
            json=_checkout_payload(rest_id, items),
        ).json()["order_id"]

        response = client.get(f"/api/v1/orders/{order_id}", headers=admin)
        assert response.status_code == 200
        assert response.json()["customer_id"] == maya_user_id(client, maya)

        listing = client.get("/api/v1/admin/orders", headers=admin)
        assert listing.status_code == 200
        assert any(o["id"] == order_id for o in listing.json()["items"])

    def test_admin_cannot_place_orders(self, client: TestClient) -> None:
        admin = _auth(client, ADMIN)
        rest_id, items = _restaurant_and_items(client, admin)
        response = client.post(
            "/api/v1/orders",
            headers={**admin, "Idempotency-Key": str(uuid.uuid4())},
            json=_checkout_payload(rest_id, items),
        )
        assert response.status_code == 403


def maya_user_id(client: TestClient, auth: dict) -> str:
    return client.get("/api/v1/me", headers=auth).json()["id"]


class TestOrderReads:
    def test_history_and_list_flow(self, client: TestClient) -> None:
        auth = _auth(client)
        rest_id, items = _restaurant_and_items(client, auth)
        order_id = client.post(
            "/api/v1/orders",
            headers={**auth, "Idempotency-Key": str(uuid.uuid4())},
            json=_checkout_payload(rest_id, items),
        ).json()["order_id"]

        detail = client.get(f"/api/v1/orders/{order_id}", headers=auth).json()
        assert detail["items"], "order detail must include line items"
        assert sum(i["line_total_minor"] for i in detail["items"]) == detail[
            "total_amount_minor"
        ]
        for item in detail["items"]:
            assert item["unit_price_minor"] > 0  # snapshot of server price
            assert item["item_name"]

        history = client.get(
            f"/api/v1/orders/{order_id}/history", headers=auth
        ).json()
        assert history["total"] == 1
        assert history["items"][0]["to_status"] == "PENDING"

        listing = client.get("/api/v1/orders", headers=auth).json()
        assert listing["total"] >= 1
        assert all(
            o["status"] in {
                "PENDING",
                "PAID",
                "CONFIRMED",
                "DRIVER_ASSIGNED",
                "PAYMENT_FAILED",
                "FAILED",
            }
            for o in listing["items"]
        )

    def test_status_filter(self, client: TestClient) -> None:
        auth = _auth(client)
        listing = client.get(
            "/api/v1/orders?status=PENDING&page_size=5", headers=auth
        )
        assert listing.status_code == 200
        assert all(o["status"] == "PENDING" for o in listing.json()["items"])

        bad = client.get("/api/v1/orders?status=NONSENSE", headers=auth)
        assert bad.status_code == 422
