"""Money helpers.

Money is exchanged as integer *minor units* everywhere (1250 == INR 12.50).
Server-side totals are computed from menu data only; client-supplied prices
are never trusted.
"""

from __future__ import annotations

from dataclasses import dataclass

DEFAULT_CURRENCY = "INR"


@dataclass(frozen=True, slots=True)
class Money:
    amount_minor: int
    currency: str = DEFAULT_CURRENCY

    def __post_init__(self) -> None:
        if not isinstance(self.amount_minor, int):
            raise TypeError("amount_minor must be an int")
        if self.amount_minor < 0:
            raise ValueError("amount_minor must be >= 0")

    def __add__(self, other: "Money") -> "Money":
        if self.currency != other.currency:
            raise ValueError("currency mismatch")
        return Money(self.amount_minor + other.amount_minor, self.currency)

    def __mul__(self, quantity: int) -> "Money":
        if quantity < 0:
            raise ValueError("quantity must be >= 0")
        return Money(self.amount_minor * quantity, self.currency)


def format_minor(amount_minor: int, currency: str = DEFAULT_CURRENCY) -> str:
    """Human-readable rendering for logs and non-numeric UI labels."""
    return f"{currency} {amount_minor / 100:.2f}"
