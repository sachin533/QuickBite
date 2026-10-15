"""Notification worker entrypoint: consumes ``notification.queue`` (``order.#``).

Persists one customer-visible notification per order event. Never drives
order state; exhausted notification retries are quarantined without
touching the order.
"""

from workers.handlers import NOTIFICATION
from workers.runtime import main

if __name__ == "__main__":
    main(NOTIFICATION)
