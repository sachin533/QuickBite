"""Admin routes: cross-customer order overview and aggregate summary.

Role enforcement happens here on the backend — a customer calling these
routes gets 403 even if the client hides the UI.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query
from sqlalchemy import func, select

from app.api.deps import CurrentAdmin, DbSession
from app.domain.enums import ORDER_STATUSES, OutboxState, RetryJobStatus
from app.models import (
    Order,
    OutboxEvent,
    QuarantineRecord,
    Restaurant,
    RetryJob,
    User,
)
from app.schemas.common import Page
from app.schemas.order import AdminOrderOut, AdminSummaryOut
from app.services.pagination import page_params

router = APIRouter(prefix="/api/v1/admin", tags=["admin"])

_STATUS_PATTERN = "^(" + "|".join(ORDER_STATUSES) + ")$"


@router.get(
    "/orders",
    response_model=Page[AdminOrderOut],
    summary="Paginated cross-customer order overview (admin only)",
)
def list_all_orders(
    db: DbSession,
    admin: CurrentAdmin,
    paging: tuple[int, int] = Depends(page_params),
    status: str | None = Query(None, pattern=_STATUS_PATTERN),
) -> Page[AdminOrderOut]:
    page, page_size = paging
    statement = select(Order).order_by(Order.created_at.desc(), Order.id.desc())
    count_statement = select(func.count()).select_from(Order)
    if status:
        statement = statement.where(Order.status == status)
        count_statement = count_statement.where(Order.status == status)

    total = int(db.scalar(count_statement) or 0)
    rows = db.scalars(
        statement.limit(page_size).offset((page - 1) * page_size)
    ).all()

    restaurant_names = dict(
        db.execute(
            select(Restaurant.id, Restaurant.name).where(
                Restaurant.id.in_({row.restaurant_id for row in rows})
            )
        ).all()
    )
    customer_emails = dict(
        db.execute(
            select(User.id, User.email).where(
                User.id.in_({row.customer_id for row in rows})
            )
        ).all()
    )

    items = [
        AdminOrderOut(
            id=row.id,
            restaurant_id=row.restaurant_id,
            restaurant_name=restaurant_names.get(row.restaurant_id),
            status=row.status,
            currency=row.currency,
            total_amount_minor=row.total_amount_minor,
            version=row.version,
            failure_code=row.failure_code,
            created_at=row.created_at,
            updated_at=row.updated_at,
            customer_email=customer_emails.get(row.customer_id),
        )
        for row in rows
    ]
    return Page(items=items, page=page, page_size=page_size, total=total)


@router.get(
    "/summary",
    response_model=AdminSummaryOut,
    summary="Counts by status plus pending outbox/retry/quarantine counts",
)
def summary(db: DbSession, admin: CurrentAdmin) -> AdminSummaryOut:
    status_rows = db.execute(
        select(Order.status, func.count()).group_by(Order.status)
    ).all()
    counts = {status: 0 for status in ORDER_STATUSES}
    counts.update({status: int(count) for status, count in status_rows})

    pending_outbox = int(
        db.scalar(
            select(func.count())
            .select_from(OutboxEvent)
            .where(OutboxEvent.state == OutboxState.PENDING.value)
        )
        or 0
    )
    pending_retries = int(
        db.scalar(
            select(func.count())
            .select_from(RetryJob)
            .where(RetryJob.status == RetryJobStatus.PENDING.value)
        )
        or 0
    )
    open_quarantine = int(
        db.scalar(
            select(func.count())
            .select_from(QuarantineRecord)
            .where(QuarantineRecord.status == "OPEN")
        )
        or 0
    )

    return AdminSummaryOut(
        orders_by_status=counts,
        total_orders=sum(counts.values()),
        pending_outbox=pending_outbox,
        pending_retries=pending_retries,
        open_quarantine=open_quarantine,
    )
