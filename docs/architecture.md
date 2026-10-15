# Architecture and event flow

Current state: **Milestone 1**. Sections marked *(later)* are implemented in
later milestones but are part of the target design.

```
 Flutter (Web / Android / iOS)                HTTPS REST
        |                                       |
        v                                       v
 +--------------------------------+   +--------------------+
 | FastAPI API service            |-->| PostgreSQL         |
 |  - auth, validation            |   |  orders, histories |
 |  - reads, admin overview       |   |  notifications     |
 |  - returns after DB commit     |   |  processed_events  |
 +--------------------------------+   |  outbox, retry_jobs|
        |        ^                    |  quarantine         |
        |        | (poll)             +---------+----------+
        |  reads state via API                  |
        |                                       | same transaction
        |                                       v
        |                            +--------------------+
        |                            | Outbox dispatcher  | (later)
        |                            | publisher confirms |
        |                            +---------+----------+
        |                                      |
        |                                      v
        |                     RabbitMQ topic exchange: quickbite.orders
        |                      |          |          |          |
        |              order.created  order.paid  order.confirmed  order.#
        |                      |          |          |          |
        |                      v          v          v          v
        |               payment      restaurant  delivery  notification
        |                worker       worker      worker      worker
        |                      |          |          |          |
        |                      +----------+----------+----------+
        |                                     |
        |            retries (targeted) <-----+----> quarantine
        |            retry scheduler (later)      quickbite.dead (later)
        v
   PostgreSQL remains the single source of order truth.
```

## Key boundaries

- **Flutter talks only to FastAPI.** Broker/database credentials never reach a
  client; `API_BASE_URL` is a public build parameter.
- **The API never waits** for payment, restaurant, delivery, or notification
  work. It commits the order, its history row, its idempotency response, and
  its outbox event in one transaction, then returns 202.
- **PostgreSQL is authoritative** for order state; the UI reads state from the
  API instead of inferring success from elapsed time.
- **Workers are separate processes** sharing the domain package and database
  (a modular training architecture, not independently owned microservices).

## Order state machine

```
PENDING ──> PAID ──> CONFIRMED ──> DRIVER_ASSIGNED   (success, terminal)
   │          │          │
   v          v          v
PAYMENT_FAILED  FAILED───┘                          (terminal)
```

- Transient failures leave the order at its last successful state.
- Notification failures never change order status.
- No backward transitions; every change bumps `orders.version` inside a
  transaction with a row lock or version compare-and-set.

## Readiness semantics

`/health/ready` requires PostgreSQL only. Broker downtime does **not** make
the API unready: accepted orders wait safely in the outbox and drain when
RabbitMQ returns (the payload still reports broker status for operators).

## Implemented in this milestone

- Config validation at startup, CORS allow-list, request-id correlation.
- `/health/live`, `/health/ready`, `/api/v1/auth/login`, `/api/v1/me`.
- 14 tables via Alembic (`0d0a1aac259d_initial_schema`), repeatable seed.
- Compose: postgres, rabbitmq, one-shot migrate + seed, API with healthchecks.
