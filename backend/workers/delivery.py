"""Delivery worker entrypoint: consumes ``delivery.queue`` (``order.confirmed``).

Assigns a simulated driver: CONFIRMED -> DRIVER_ASSIGNED (emits
``order.driver.assigned``) or FAILED after bounded retries are exhausted.
DRIVER_ASSIGNED is successful completion for this assignment.
"""

from workers.handlers import DELIVERY
from workers.runtime import main

if __name__ == "__main__":
    main(DELIVERY)
