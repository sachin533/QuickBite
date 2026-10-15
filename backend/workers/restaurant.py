"""Restaurant worker entrypoint: consumes ``restaurant.queue`` (``order.paid``).

Simulates restaurant acceptance: PAID -> CONFIRMED (emits
``order.confirmed``) or FAILED after bounded retries are exhausted.
"""

from workers.handlers import RESTAURANT
from workers.runtime import main

if __name__ == "__main__":
    main(RESTAURANT)
