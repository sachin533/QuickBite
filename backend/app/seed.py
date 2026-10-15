"""Repeatable database seeding.

Run:  python -m app.seed            (idempotent: creates only what is missing)
      python -m app.seed --reset    (wipe transactional tables, then seed)

Seeded accounts (fictional, documented in the README):

    customer: maya@quickbite.dev    / demo12345
    customer: arjun@quickbite.dev   / demo12345
    admin:    admin@quickbite.dev   / admin12345

Money is integer minor units: 1250 == INR 12.50.
"""

from __future__ import annotations

import argparse
import sys

from sqlalchemy import delete

from app.db import Base, engine, session_scope
from app.domain.enums import UserRole
from app.domain.ids import new_menu_item_id, new_restaurant_id, new_user_id
from app.models import (
    DriverAssignment,
    IdempotencyKey,
    MenuItem,
    Notification,
    Order,
    OrderItem,
    OrderStatusHistory,
    OutboxEvent,
    ProcessedEvent,
    QuarantineRecord,
    Restaurant,
    RetryJob,
    SimulatedPayment,
    User,
)
from app.security import hash_password

PASSWORDS = {
    "maya@quickbite.dev": "demo12345",
    "arjun@quickbite.dev": "demo12345",
    "admin@quickbite.dev": "admin12345",
}

# (email, full_name, role)
ACCOUNTS = [
    ("maya@quickbite.dev", "Maya Sharma", UserRole.CUSTOMER.value),
    ("arjun@quickbite.dev", "Arjun Patel", UserRole.CUSTOMER.value),
    ("admin@quickbite.dev", "QuickBite Ops", UserRole.ADMIN.value),
]

# name, cuisine, description, eta, [(item name, category, price_minor, available)]
RESTAURANTS: list[tuple] = [
    (
        "Biryani Blues",
        "Indian",
        "Slow-cooked dum biryani and kebabs.",
        35,
        [
            ("Chicken Dum Biryani", "Main", 32500, True),
            ("Mutton Biryani", "Main", 42000, True),
            ("Veg Handi Biryani", "Main", 26500, True),
            ("Galouti Kebab", "Starters", 24000, True),
            ("Double Ka Meetha", "Desserts", 12000, True),
            ("Sweet Lassi", "Beverages", 9000, True),
        ],
    ),
    (
        "Pizza Parlour",
        "Italian",
        "Stone-baked pizzas and fresh pasta.",
        25,
        [
            ("Margherita", "Pizza", 21900, True),
            ("Farmhouse Pizza", "Pizza", 28900, True),
            ("Peri Peri Paneer Pizza", "Pizza", 29900, True),
            ("Alfredo Pasta", "Pasta", 25500, True),
            ("Garlic Bread", "Sides", 11900, True),
            ("Choco Lava Cake", "Desserts", 9900, False),
        ],
    ),
    (
        "Green Bowl",
        "Healthy",
        "Salads, bowls, and cold-pressed juice.",
        20,
        [
            ("Quinoa Bowl", "Bowls", 27500, True),
            ("Grilled Paneer Salad", "Salads", 23500, True),
            ("Avocado Toast", "Breakfast", 18500, True),
            ("Orange Juice", "Beverages", 9500, True),
        ],
    ),
    (
        "Wok Express",
        "Asian",
        "Fast wok-tossed noodles and dim sum.",
        30,
        [
            ("Veg Hakka Noodles", "Main", 19500, True),
            ("Chicken Fried Rice", "Main", 22500, True),
            ("Chilli Paneer", "Starters", 21500, True),
            ("Steamed Dim Sum", "Starters", 17500, True),
            ("Hot Chocolate Soup", "Soups", 13500, True),
        ],
    ),
    (
        "Chai Point",
        "Beverages",
        "Tea, snacks, and quick bites all day.",
        15,
        [
            ("Masala Chai", "Beverages", 4500, True),
            ("Cutting Chai", "Beverages", 3000, True),
            ("Samosa (2 pc)", "Snacks", 8000, True),
            ("Veg Puff", "Snacks", 7000, True),
            ("Banana Bread", "Bakery", 9500, True),
        ],
    ),
]

# Tables emptied by --reset, in FK-safe order.
RESET_TABLES = [
    IdempotencyKey,
    QuarantineRecord,
    RetryJob,
    OutboxEvent,
    ProcessedEvent,
    Notification,
    DriverAssignment,
    SimulatedPayment,
    OrderStatusHistory,
    OrderItem,
    Order,
    MenuItem,
    Restaurant,
    User,
]


def seed(reset: bool = False) -> dict[str, int]:
    with session_scope() as session:
        if reset:
            for model in RESET_TABLES:
                session.execute(delete(model))

        created = {"users": 0, "restaurants": 0, "menu_items": 0}

        for email, full_name, role in ACCOUNTS:
            exists = session.query(User).filter(User.email == email).one_or_none()
            if exists:
                continue
            session.add(
                User(
                    id=new_user_id(),
                    email=email,
                    password_hash=hash_password(PASSWORDS[email]),
                    full_name=full_name,
                    role=role,
                    is_active=True,
                )
            )
            created["users"] += 1

        for name, cuisine, description, eta, items in RESTAURANTS:
            restaurant = (
                session.query(Restaurant)
                .filter(Restaurant.name == name)
                .one_or_none()
            )
            if restaurant is None:
                restaurant = Restaurant(
                    id=new_restaurant_id(),
                    name=name,
                    description=description,
                    cuisine=cuisine,
                    currency="INR",
                    is_open=True,
                    rating=5,
                    eta_minutes=eta,
                )
                session.add(restaurant)
                session.flush()
                created["restaurants"] += 1

            for sort_order, (item_name, category, price_minor, available) in enumerate(
                items
            ):
                exists = (
                    session.query(MenuItem)
                    .filter(
                        MenuItem.restaurant_id == restaurant.id,
                        MenuItem.name == item_name,
                    )
                    .one_or_none()
                )
                if exists:
                    continue
                session.add(
                    MenuItem(
                        id=new_menu_item_id(),
                        restaurant_id=restaurant.id,
                        name=item_name,
                        description=f"{item_name} from {name}",
                        category=category,
                        price_minor=price_minor,
                        is_available=available,
                        sort_order=sort_order,
                    )
                )
                created["menu_items"] += 1

    return created


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Seed QuickBite demo data")
    parser.add_argument(
        "--reset",
        action="store_true",
        help="Delete orders, users, menus, and operational tables first",
    )
    args = parser.parse_args(argv)

    if args.reset:
        Base.metadata.create_all(engine)  # ensure schema exists pre-alembic

    created = seed(reset=args.reset)
    print(
        "seed complete: "
        f"+{created['users']} users, "
        f"+{created['restaurants']} restaurants, "
        f"+{created['menu_items']} menu items"
    )
    if created["users"] == 0 and created["restaurants"] == 0:
        print("nothing to do (already seeded)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
