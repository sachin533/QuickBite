"""Payment worker entrypoint: consumes ``payment.queue`` (``order.created``).

Simulates the payment provider: PENDING -> PAID (emits ``order.paid``) or
PAYMENT_FAILED after bounded retries are exhausted.
"""

from workers.handlers import PAYMENT
from workers.runtime import main

if __name__ == "__main__":
    main(PAYMENT)
