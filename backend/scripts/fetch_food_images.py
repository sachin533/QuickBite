"""Download real food photography for the seeded menu into the Flutter assets.

Images come from Wikimedia Commons (key-free, freely licensed). For each dish
we try each search query in order and keep the first hit, then downscale to
640px wide JPEGs so the web bundle stays small (~40-60 KB each).

Run:  py backend/scripts/fetch_food_images.py
Output: frontend/assets/food/<slug>.jpg
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "frontend" / "assets" / "food"
UA = "QuickBiteDemo/1.0 (training assignment; contact: local)"
MAX_W = 640
TARGET_BYTES = 90_000  # quality is lowered until the JPEG fits under this
# Wikimedia Commons throttles anonymous API clients hard; stay well under it.
REQUEST_GAP_SECONDS = 2.0
MAX_ATTEMPTS = 5

# slug -> ordered list of Commons search queries (first non-empty wins)
DISHES: dict[str, list[str]] = {
    # --- Biryani Blues: biryani and rice -------------------------------
    "chicken_dum_biryani": ["chicken dum biryani", "chicken biryani"],
    "mutton_biryani": ["mutton biryani", "goat biryani"],
    "veg_handi_biryani": ["vegetable biryani", "veg biryani"],
    "galouti_kebab": ["galouti kebab", "kebab seekh"],
    "double_ka_meetha": ["double ka meetha", "bread pudding saffron"],
    "sweet_lassi": ["sweet lassi", "lassi drink"],
    "awadhi_mutton_biryani": ["awadhi biryani", "lucknowi biryani"],
    "prawn_biryani": ["prawn biryani", "seafood biryani"],
    "veg_kolhapuri_biryani": ["kolhapuri biryani", "spicy vegetable rice"],
    "hyderabadi_egg_biryani": ["egg biryani", "andedum biryani"],
    "jeera_rice": ["jeera rice", "cumin rice"],
    "kashmiri_pulao": ["kashmiri pulao", "pulao rice"],
    # --- Pizza Parlour: pizzas -----------------------------------------
    "margherita": ["margherita pizza", "pizza margherita"],
    "farmhouse_pizza": ["vegetable pizza", "veggie pizza"],
    "peri_peri_paneer_pizza": ["paneer pizza", "cheese pizza"],
    "pepperoni_pizza": ["pepperoni pizza", "pizza pepperoni"],
    "bbq_chicken_pizza": ["barbecue chicken pizza", "chicken pizza"],
    "four_cheese_pizza": ["four cheese pizza", "cheese pizza"],
    "truffle_mushroom_pizza": ["mushroom pizza", "pizza funghi"],
    "tandoori_paneer_pizza": ["tandoori paneer pizza", "indian pizza"],
    "mexicana_pizza": ["mexican pizza", "pizza jalapeno"],
    "alfredo_pasta": ["alfredo pasta", "pasta alfredo"],
    "garlic_bread": ["garlic bread", "breadsticks garlic"],
    "choco_lava_cake": ["chocolate lava cake", "molten chocolate cake"],
    # --- Burger Junction: burgers and sandwiches -----------------------
    "classic_cheeseburger": ["cheeseburger", "burger cheese"],
    "double_patty_burger": ["double burger", "burger beef patty"],
    "crispy_veg_burger": ["veggie burger", "vegetable burger"],
    "grilled_chicken_sandwich": ["chicken sandwich", "grilled sandwich"],
    "club_sandwich": ["club sandwich", "triple decker sandwich"],
    "paneer_tikka_sandwich": ["paneer sandwich", "grilled cheese sandwich"],
    # --- Wok Express: Chinese ------------------------------------------
    "veg_hakka_noodles": ["hakka noodles", "chow mein noodles"],
    "chicken_fried_rice": ["chicken fried rice", "fried rice"],
    "chilli_paneer": ["chilli paneer", "paneer chili"],
    "steamed_dim_sum": ["dim sum", "steamed dumplings"],
    "hot_chocolate_soup": ["cream of mushroom soup", "creamy soup bowl"],
    "schezwan_fried_rice": ["schezwan fried rice", "spicy fried rice"],
    "chicken_chow_mein": ["chicken chow mein", "noodles stir fry"],
    "sweet_and_sour_chicken": ["sweet and sour chicken", "chinese chicken"],
    "kung_pao_chicken": ["kung pao chicken", "kung pao"],
    "wonton_soup": ["wonton soup", "wonton"],
    "chilli_chicken": ["chilli chicken", "chinese chicken dish"],
    # --- Dosa Hut: South Indian ----------------------------------------
    "masala_dosa": ["masala dosa", "dosa"],
    "mysore_masala_dosa": ["mysore dosa", "dosa red chutney"],
    "idli_vada_combo": ["idli vada", "idli sambar"],
    "paneer_uttapam": ["uttapam", "pancake south indian"],
    "medu_vada": ["medu vada", "vada fritter"],
    # --- Chai Point: snacks and sides ----------------------------------
    "masala_chai": ["masala chai", "indian tea"],
    "cutting_chai": ["cutting chai", "street tea india"],
    "samosa": ["samosa", "indian samosa"],
    "veg_puff": ["vegetable puff", "puff pastry snack"],
    "banana_bread": ["banana bread", "banana loaf"],
    "pav_bhaji": ["pav bhaji", "bhaji pav"],
    "paneer_tikka_roll": ["paneer roll", "kathi roll"],
    "aloo_tikki_chaat": ["aloo tikki", "chaat snack"],
    "masala_peanuts": ["masala peanuts", "spiced peanuts"],
    "chilli_cheese_fries": ["cheese fries", "loaded fries"],
    "masala_cold_coffee": ["cold coffee", "iced coffee"],
    "almond_brownie": ["chocolate brownie", "brownie square"],
    # --- Green Bowl: healthy --------------------------------------------
    "quinoa_bowl": ["quinoa bowl", "quinoa salad"],
    "grilled_paneer_salad": ["paneer salad", "grilled cheese salad"],
    "avocado_toast": ["avocado toast", "avocado bread"],
    "orange_juice": ["orange juice", "fresh orange juice"],
    "watermelon_cooler": ["watermelon juice", "watermelon drink"],
    "detox_green_juice": ["green juice", "vegetable juice"],
    "greek_yogurt_parfait": ["yogurt parfait", "granola yogurt"],
    "chocolate_protein_shake": ["protein shake", "chocolate milkshake"],
    # --- restaurant hero images -----------------------------------------
    "rest_biryani_blues": ["biryani platter", "biryani serving"],
    "rest_pizza_parlour": ["pizza restaurant", "pizza stone baked"],
    "rest_green_bowl": ["healthy salad bowl", "buddha bowl"],
    "rest_wok_express": ["wok cooking", "stir fry wok"],
    "rest_chai_point": ["indian tea stall", "chai kettle"],
    "rest_burger_junction": ["burger fries", "burger meal"],
    "rest_dosa_hut": ["south indian food", "dosa platter sambar"],
}

# First image from the search results is normally the best match, but on a
# miss we want a real food photo rather than a coat of arms or a map.
BLOCKED_HINTS = (
    "map",
    "logo",
    "coat of arms",
    "flag",
    "banner",
    "icon",
    "sign",
    "poster",
    "diagram",
    "chart",
    "building",
    "street",
    "portrait",
)


def _safe(text: str) -> str:
    """Titles can contain non-ASCII; the Windows console may not."""
    return text.encode("ascii", "replace").decode("ascii")


def _fetch(url: str, timeout: int = 45) -> bytes:
    """GET with a polite gap between calls and backoff on 429/5xx."""
    last_error: Exception | None = None
    for attempt in range(MAX_ATTEMPTS):
        # Global pacing: every network call waits, not just retries.
        time.sleep(REQUEST_GAP_SECONDS)
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            last_error = exc
            if exc.code in (429, 503, 502, 500):
                # Retry-After wins when the server sends one.
                wait = float(exc.headers.get("Retry-After", 0) or 0)
                time.sleep(max(wait, 2.0 * (attempt + 1)))
                continue
            raise
        except Exception as exc:  # transient network error
            last_error = exc
            time.sleep(2.0 * (attempt + 1))
    raise last_error  # type: ignore[misc]


def commons_search(query: str, limit: int = 5) -> list[tuple[str, str]]:
    """Return (title, thumb_url) candidates for a Commons full-text search."""
    params = urllib.parse.urlencode(
        {
            "action": "query",
            "generator": "search",
            "gsrsearch": f"{query} filetype:bitmap",
            "gsrlimit": limit,
            "gsrnamespace": 6,
            "prop": "imageinfo",
            "iiprop": "url|size|mime",
            "iiurlwidth": MAX_W * 2,
            "format": "json",
        }
    )
    try:
        payload = json.loads(_fetch(f"https://commons.wikimedia.org/w/api.php?{params}").decode("utf-8"))
    except Exception as exc:  # network/parse failure -> caller tries next query
        print(f"    ! search failed for {query!r}: {exc}")
        return []

    pages = (payload.get("query") or {}).get("pages") or {}
    # generator=search returns an unordered dict; order by 'index'.
    ordered = sorted(pages.values(), key=lambda p: p.get("index", 0))
    out: list[tuple[str, str]] = []
    for page in ordered:
        info = (page.get("imageinfo") or [{}])[0]
        url = info.get("thumburl") or info.get("url")
        if not url:
            continue
        if info.get("mime") not in (None, "image/jpeg", "image/png", "image/webp"):
            continue
        title = (page.get("title") or "").lower()
        if any(bad in title for bad in BLOCKED_HINTS):
            continue
        out.append((page.get("title", ""), url))
    return out


def download(url: str, dest: Path) -> bool:
    try:
        data = _fetch(url, timeout=60)
    except Exception as exc:
        print(f"    ! download failed: {exc}")
        return False
    if len(data) < 4096:
        return False
    tmp = dest.with_suffix(".src")
    tmp.write_bytes(data)
    try:
        with Image.open(tmp) as im:
            im = im.convert("RGB")
            if im.width > MAX_W:
                im = im.resize(
                    (MAX_W, max(1, round(im.height * MAX_W / im.width))),
                    Image.LANCZOS,
                )
            quality = 82
            im.save(dest, "JPEG", quality=quality, optimize=True, progressive=True)
            while dest.stat().st_size > TARGET_BYTES and quality > 45:
                quality -= 10
                im.save(dest, "JPEG", quality=quality, optimize=True, progressive=True)
    except Exception as exc:
        print(f"    ! decode/resize failed: {exc}")
        if dest.exists():
            dest.unlink()
        return False
    finally:
        if tmp.exists():
            tmp.unlink()
    return True


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    only = set(sys.argv[1:])
    wanted = {k: v for k, v in DISHES.items() if not only or k in only}

    ok = skipped = failed = 0
    for slug, queries in wanted.items():
        dest = OUT / f"{slug}.jpg"
        if dest.exists() and dest.stat().st_size > 4096:
            skipped += 1
            continue
        done = False
        for query in queries:
            for title, url in commons_search(query):
                print(f"{slug:32} <- {_safe(title)[:60]}")
                if download(url, dest):
                    done = True
                    break
            if done:
                break
        if done:
            ok += 1
        else:
            failed += 1
            print(f"{slug:32} !! NO IMAGE FOUND")

    print(f"\ndownloaded={ok} skipped_existing={skipped} failed={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
