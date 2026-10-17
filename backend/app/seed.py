"""Repeatable database seeding.

Run:  python -m app.seed            (idempotent: creates only what is missing)
      python -m app.seed --reset    (wipe transactional tables, then seed)

Seeded accounts (fictional, documented in the README):

    customer: maya@quickbite.dev    / demo12345
    customer: arjun@quickbite.dev   / demo12345
    admin:    admin@quickbite.dev   / admin12345

Money is integer minor units: 1250 == INR 12.50.

Catalogue shape
---------------
26 original items + 40 new items = 66 across 7 kitchens, distributed as:

    6 biryani & rice   -> Biryani Blues
    6 pizzas           -> Pizza Parlour
    6 burgers/sandwich -> Burger Junction   (new restaurant)
    6 Chinese          -> Wok Express
    5 South Indian     -> Dosa Hut          (new restaurant)
    5 snacks & sides   -> Chai Point
    6 desserts/bev.    -> Green Bowl + Chai Point

Every item carries an ``image_url`` pointing at a bundled real photograph
(``assets/food/<slug>.jpg`` — see ``backend/scripts/fetch_food_images.py``),
so the UI never shows a broken or repeated image.
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


def asset(slug: str) -> str:
    """Bundled photograph reference for a menu item or restaurant."""
    return f"assets/food/{slug}.jpg"


# name, cuisine, description, eta, image_slug,
# items: (name, category, price_minor, available, description, image_slug)
RESTAURANTS: list[tuple] = [
    (
        "Biryani Blues",
        "Indian",
        "Slow-cooked dum biryani and kebabs.",
        35,
        "rest_biryani_blues",
        [
            # --- original six ---
            ("Chicken Dum Biryani", "Main", 32500, True,
             "Long-grain basmati layered with chicken, fried onions and saffron.",
             "chicken_dum_biryani"),
            ("Mutton Biryani", "Main", 42000, True,
             "Tender goat slow-cooked with aromatic spices and mint.",
             "mutton_biryani"),
            ("Veg Handi Biryani", "Main", 26500, True,
             "Seasonal vegetables and paneer simmered in a clay handi.",
             "veg_handi_biryani"),
            ("Galouti Kebab", "Starters", 24000, True,
             "Melt-in-the-mouth minced kebabs with raw papaya.",
             "galouti_kebab"),
            ("Double Ka Meetha", "Desserts", 12000, True,
             "Hyderabadi bread pudding with saffron milk and dry fruits.",
             "double_ka_meetha"),
            ("Sweet Lassi", "Beverages", 9000, True,
             "Thick curd blended with sugar and a pinch of cardamom.",
             "sweet_lassi"),
            # --- new: biryani & rice (6) ---
            ("Awadhi Mutton Biryani", "Main", 44500, True,
             "Lucknowi mutton biryani sealed with dough and cooked on dum.",
             "awadhi_mutton_biryani"),
            ("Prawn Biryani", "Main", 46500, True,
             "Coastal prawns tossed with basmati, coconut masala and curry leaf.",
             "prawn_biryani"),
            ("Veg Kolhapuri Biryani", "Main", 27500, True,
             "Fiery Kolchapuri gravy folded into fragrant long-grain rice.",
             "veg_kolhapuri_biryani"),
            ("Hyderabadi Egg Biryani", "Main", 29500, True,
             "Spiced rice layered with fried eggs, fried onion and mint.",
             "hyderabadi_egg_biryani"),
            ("Jeera Rice", "Sides", 16500, True,
             "Basmati tempered with ghee-roasted cumin and coriander.",
             "jeera_rice"),
            ("Kashmiri Pulao", "Main", 21500, True,
             "Sweet-savoury rice with saffron, nuts and pomegranate seeds.",
             "kashmiri_pulao"),
        ],
    ),
    (
        "Pizza Parlour",
        "Italian",
        "Stone-baked pizzas and fresh pasta.",
        25,
        "rest_pizza_parlour",
        [
            # --- original six ---
            ("Margherita", "Pizza", 21900, True,
             "Tomato, fior di latte and basil on a thin stone-baked base.",
             "margherita"),
            ("Farmhouse Pizza", "Pizza", 28900, True,
             "Capsicum, onion, mushroom, olives and extra cheese.",
             "farmhouse_pizza"),
            ("Peri Peri Paneer Pizza", "Pizza", 29900, True,
             "Cottage cheese cubes dusted with peri peri masala.",
             "peri_peri_paneer_pizza"),
            ("Alfredo Pasta", "Pasta", 25500, True,
             "Penne in a silky white sauce with garlic and herbs.",
             "alfredo_pasta"),
            ("Garlic Bread", "Sides", 11900, True,
             "Oven-baked breadsticks with garlic butter and oregano.",
             "garlic_bread"),
            ("Choco Lava Cake", "Desserts", 9900, False,
             "Molten chocolate centre sponge — temporarily unavailable.",
             "choco_lava_cake"),
            # --- new: pizzas (6) ---
            ("Pepperoni Pizza", "Pizza", 34900, True,
             "Cured pepperoni, mozzarella and a scatter of chilli flakes.",
             "pepperoni_pizza"),
            ("BBQ Chicken Pizza", "Pizza", 36900, True,
             "Smoky barbecue chicken, red onion and sharp cheddar.",
             "bbq_chicken_pizza"),
            ("Four Cheese Pizza", "Pizza", 38900, True,
             "Mozzarella, gouda, parmesan and blue cheese melted together.",
             "four_cheese_pizza"),
            ("Truffle Mushroom Pizza", "Pizza", 42500, True,
             "Wild mushrooms, truffle oil and fontina on a white base.",
             "truffle_mushroom_pizza"),
            ("Tandoori Paneer Pizza", "Pizza", 32900, True,
             "Tandoori-spiced paneer, onion and coriander on a charred crust.",
             "tandoori_paneer_pizza"),
            ("Mexicana Pizza", "Pizza", 31900, True,
             "Jalapeño, sweet corn, beans and cheddar with a lime drizzle.",
             "mexicana_pizza"),
        ],
    ),
    (
        "Burger Junction",
        "American",
        "Smashed patties, toasted buns and loaded fries.",
        20,
        "rest_burger_junction",
        [
            # --- new: burgers & sandwiches (6) ---
            ("Classic Cheeseburger", "Burgers", 24900, True,
             "Smashed beef patty, cheddar, pickles and house burger sauce.",
             "classic_cheeseburger"),
            ("Double Patty Burger", "Burgers", 34900, True,
             "Two smashed patties double-stacked with molten cheese.",
             "double_patty_burger"),
            ("Crispy Veg Burger", "Burgers", 18900, True,
             "Crumb-fried vegetable patty with lettuce and toasted sesame bun.",
             "crispy_veg_burger"),
            ("Grilled Chicken Sandwich", "Sandwiches", 25900, True,
             "Char-grilled chicken breast, slaw and mustard mayo on sourdough.",
             "grilled_chicken_sandwich"),
            ("Club Sandwich", "Sandwiches", 22900, True,
             "Triple-decker toast with egg, bacon, lettuce and tomato.",
             "club_sandwich"),
            ("Paneer Tikka Sandwich", "Sandwiches", 20900, True,
             "Tandoori paneer, onion and mint chutney pressed and grilled.",
             "paneer_tikka_sandwich"),
        ],
    ),
    (
        "Wok Express",
        "Asian",
        "Fast wok-tossed noodles and dim sum.",
        30,
        "rest_wok_express",
        [
            # --- original five ---
            ("Veg Hakka Noodles", "Main", 19500, True,
             "Wok-tossed noodles with julienne vegetables.",
             "veg_hakka_noodles"),
            ("Chicken Fried Rice", "Main", 22500, True,
             "Long-grain rice tossed with egg and chicken.",
             "chicken_fried_rice"),
            ("Chilli Paneer", "Starters", 21500, True,
             "Crisp paneer tossed with capsicum and chilli sauce.",
             "chilli_paneer"),
            ("Steamed Dim Sum", "Starters", 17500, True,
             "Chicken dumplings steamed in bamboo baskets.",
             "steamed_dim_sum"),
            ("Hot Chocolate Soup", "Soups", 13500, True,
             "Silky cocoa soup topped with cream.",
             "hot_chocolate_soup"),
            # --- new: Chinese (6) ---
            ("Schezwan Fried Rice", "Main", 21500, True,
             "Fried rice tossed in fiery house schezwan sauce.",
             "schezwan_fried_rice"),
            ("Chicken Chow Mein", "Main", 23500, True,
             "Hakka noodles with shredded chicken and spring onion.",
             "chicken_chow_mein"),
            ("Sweet & Sour Chicken", "Main", 27500, True,
             "Battered chicken glazed with pineapple and vinegar sauce.",
             "sweet_and_sour_chicken"),
            ("Kung Pao Chicken", "Main", 29500, True,
             "Wok-seared chicken with dried chilli, peanut and garlic.",
             "kung_pao_chicken"),
            ("Wonton Soup", "Soups", 15500, True,
             "Chicken wontons in a clear ginger-scallion broth.",
             "wonton_soup"),
            ("Chilli Chicken", "Starters", 24500, True,
             "Dry-fried chicken tossed with garlic, chilli and onion.",
             "chilli_chicken"),
        ],
    ),
    (
        "Dosa Hut",
        "South Indian",
        "Crisp dosas, soft idlis and filter coffee.",
        18,
        "rest_dosa_hut",
        [
            # --- new: South Indian (5) ---
            ("Masala Dosa", "Main", 14900, True,
             "Golden crisp crepe folded over spiced potato, with sambar.",
             "masala_dosa"),
            ("Mysore Masala Dosa", "Main", 16900, True,
             "Dosa brushed with red garlic chutney before the potato filling.",
             "mysore_masala_dosa"),
            ("Idli Vada Combo", "Breakfast", 13900, True,
             "Steamed idlis and crisp medu vada with sambar and chutney.",
             "idli_vada_combo"),
            ("Paneer Uttapam", "Main", 17900, True,
             "Thick rice pancake topped with paneer, onion and coriander.",
             "paneer_uttapam"),
            ("Medu Vada", "Starters", 11900, True,
             "Crisp lentil doughnuts with a fluffy centre and hot sambar.",
             "medu_vada"),
        ],
    ),
    (
        "Chai Point",
        "Beverages",
        "Tea, snacks, and quick bites all day.",
        15,
        "rest_chai_point",
        [
            # --- original five ---
            ("Masala Chai", "Beverages", 4500, True,
             "Assam tea simmered with milk, ginger and cardamom.",
             "masala_chai"),
            ("Cutting Chai", "Beverages", 3000, True,
             "Strong half-glass chai, the way the streets make it.",
             "cutting_chai"),
            ("Samosa (2 pc)", "Snacks", 8000, True,
             "Flaky pastry filled with spiced potatoes and peas.",
             "samosa"),
            ("Veg Puff", "Snacks", 7000, True,
             "Buttery puff pastry with a savoury vegetable core.",
             "veg_puff"),
            ("Banana Bread", "Bakery", 9500, True,
             "Moist loaf studded with ripe banana and walnuts.",
             "banana_bread"),
            # --- new: snacks & sides (5) ---
            ("Pav Bhaji", "Snacks", 15500, True,
             "Buttered mashed vegetables with soft toasted pav.",
             "pav_bhaji"),
            ("Paneer Tikka Roll", "Snacks", 16500, True,
             "Roll-up of tandoori paneer, onions and mint chutney.",
             "paneer_tikka_roll"),
            ("Aloo Tikki Chaat", "Snacks", 12500, True,
             "Crisp potato patties with yogurt, tamarind and sev.",
             "aloo_tikki_chaat"),
            ("Masala Peanuts", "Sides", 7500, True,
             "Roasted peanuts tossed with chilli, curry leaf and lime.",
             "masala_peanuts"),
            ("Chilli Cheese Fries", "Sides", 14500, True,
             "Skin-on fries under molten cheese and green chilli.",
             "chilli_cheese_fries"),
            # --- new: desserts & beverages (2 of 6) ---
            ("Masala Cold Coffee", "Beverages", 11500, True,
             "Blended iced coffee with a dusting of cocoa.",
             "masala_cold_coffee"),
            ("Almond Brownie", "Desserts", 14500, True,
             "Fudgy dark chocolate brownie with almond slivers.",
             "almond_brownie"),
        ],
    ),
    (
        "Green Bowl",
        "Healthy",
        "Salads, bowls, and cold-pressed juice.",
        20,
        "rest_green_bowl",
        [
            # --- original four ---
            ("Quinoa Bowl", "Bowls", 27500, True,
             "Quinoa, roasted vegetables and tahini dressing.",
             "quinoa_bowl"),
            ("Grilled Paneer Salad", "Salads", 23500, True,
             "Char-grilled paneer over crisp greens and vinaigrette.",
             "grilled_paneer_salad"),
            ("Avocado Toast", "Breakfast", 18500, True,
             "Smashed avocado on sourdough with chilli flakes.",
             "avocado_toast"),
            ("Orange Juice", "Beverages", 9500, True,
             "Freshly cold-pressed oranges, no added sugar.",
             "orange_juice"),
            # --- new: desserts & beverages (4 of 6) ---
            ("Watermelon Cooler", "Beverages", 9500, True,
             "Chilled watermelon juice with mint and lime.",
             "watermelon_cooler"),
            ("Detox Green Juice", "Beverages", 12500, True,
             "Cucumber, celery, green apple and ginger press.",
             "detox_green_juice"),
            ("Greek Yogurt Parfait", "Desserts", 15500, True,
             "Layered yogurt with granola and seasonal berries.",
             "greek_yogurt_parfait"),
            ("Chocolate Protein Shake", "Beverages", 17500, True,
             "Cocoa, banana and peanut butter blended with milk.",
             "chocolate_protein_shake"),
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
        updated = {"restaurants": 0, "menu_items": 0}

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

        for name, cuisine, description, eta, image_slug, items in RESTAURANTS:
            image_url = asset(image_slug)
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
                    image_url=image_url,
                    is_open=True,
                    rating=5,
                    eta_minutes=eta,
                )
                session.add(restaurant)
                session.flush()
                created["restaurants"] += 1
            elif restaurant.image_url != image_url:
                # The seed owns the presentation copy for a demo kitchen.
                restaurant.image_url = image_url
                updated["restaurants"] += 1

            for sort_order, item in enumerate(items):
                (
                    item_name,
                    category,
                    price_minor,
                    available,
                    blurb,
                    item_image_slug,
                ) = item
                item_image_url = asset(item_image_slug)
                existing = (
                    session.query(MenuItem)
                    .filter(
                        MenuItem.restaurant_id == restaurant.id,
                        MenuItem.name == item_name,
                    )
                    .one_or_none()
                )
                if existing is None:
                    session.add(
                        MenuItem(
                            id=new_menu_item_id(),
                            restaurant_id=restaurant.id,
                            name=item_name,
                            description=blurb,
                            category=category,
                            price_minor=price_minor,
                            is_available=available,
                            sort_order=sort_order,
                            image_url=item_image_url,
                        )
                    )
                    created["menu_items"] += 1
                else:
                    # The seed owns the copy and the picture reference. Refreshing
                    # them keeps re-runs idempotent (never duplicates a row) while
                    # picking up edits and back-filling images on an existing DB.
                    # Prices/availability are never touched, so live catalogue
                    # data (sold-out flags, price changes) is not overwritten.
                    if existing.description != blurb:
                        existing.description = blurb
                        updated["menu_items"] += 1
                    if existing.image_url != item_image_url:
                        existing.image_url = item_image_url
                        updated["menu_items"] += 1
                    if existing.category != category:
                        existing.category = category
                        updated["menu_items"] += 1

        session.flush()
        created["updated"] = sum(updated.values())

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

    result = seed(reset=args.reset)
    print(
        "seed complete: "
        f"+{result['users']} users, "
        f"+{result['restaurants']} restaurants, "
        f"+{result['menu_items']} menu items, "
        f"~{result['updated']} refreshed"
    )
    if result["users"] == 0 and result["restaurants"] == 0:
        print("nothing to do (already seeded)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
