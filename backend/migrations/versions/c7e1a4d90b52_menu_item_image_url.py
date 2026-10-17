"""menu item image_url

Revision ID: c7e1a4d90b52
Revises: 9ecf3dfbd89b
Create Date: 2026-10-15 14:10:00.000000

Adds an optional image reference to menu items so the catalogue can render
real food photography. Nullable, so every existing row keeps working and the
column can be back-filled by a plain UPDATE.
"""
from __future__ import annotations

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'c7e1a4d90b52'
down_revision: Union[str, None] = '9ecf3dfbd89b'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        'menu_items',
        sa.Column('image_url', sa.String(length=500), nullable=True),
    )


def downgrade() -> None:
    op.drop_column('menu_items', 'image_url')
