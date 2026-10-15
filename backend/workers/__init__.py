"""Worker processes: payment, restaurant, delivery, notification, plus the
outbox dispatcher and retry scheduler.

Each worker is an independently runnable process:

    python -m workers.payment
    python -m workers.restaurant
    python -m workers.delivery
    python -m workers.notification
    python -m workers.outbox_dispatcher
    python -m workers.retry_scheduler
"""
