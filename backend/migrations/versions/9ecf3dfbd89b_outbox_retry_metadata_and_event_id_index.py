"""outbox retry metadata and event id index

Revision ID: 9ecf3dfbd89b
Revises: 0d0a1aac259d
Create Date: 2026-10-15 12:01:06.530569

"""
from __future__ import annotations

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = '9ecf3dfbd89b'
down_revision: Union[str, None] = '0d0a1aac259d'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('outbox_events', sa.Column('retry_attempt', sa.Integer(), nullable=True))
    op.drop_constraint(op.f('outbox_events_event_id_key'), 'outbox_events', type_='unique')
    op.create_index('ix_outbox_event_id', 'outbox_events', ['event_id'], unique=False)
    # SCHEDULED: a due-in-the-future retry publication. The retry scheduler
    # flips these rows to PENDING when their time comes. (Autogenerate does
    # not detect check-constraint content changes — added by hand.)
    op.drop_constraint('ck_outbox_state', 'outbox_events', type_='check')
    op.create_check_constraint(
        'ck_outbox_state',
        'outbox_events',
        "state IN ('PENDING','SCHEDULED','SENDING','SENT','FAILED')",
    )


def downgrade() -> None:
    op.drop_constraint('ck_outbox_state', 'outbox_events', type_='check')
    op.create_check_constraint(
        'ck_outbox_state',
        'outbox_events',
        "state IN ('PENDING','SENDING','SENT','FAILED')",
    )
    op.drop_index(op.f('ix_outbox_event_id'), table_name='outbox_events')
    op.create_unique_constraint(
        op.f('outbox_events_event_id_key'),
        'outbox_events',
        ['event_id'],
        postgresql_nulls_not_distinct=False,
    )
    op.drop_column('outbox_events', 'retry_attempt')
