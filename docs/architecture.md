# Architecture and event flow

Current state: **Milestone 3** — the asynchronous pipeline (outbox
dispatcher, four workers, bounded retries, quarantine) is live.

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
        |        |                            | same transaction
        |        |                            v
        |        |                 +--------------------+
        |        |                  | Outbox dispatcher  |
        |        |                  | confirms + mandatory
        |        |                  +---------+----------+
        |        |                            |
        |        |                            v
        |        |          RabbitMQ topic exchange: quickbite.orders
        |        |           |           |            |            |
        |        |    order.created   order.paid  order.confirmed  order.#
        |        |           |           |            |            |
        |        |           v           v            v            v
        |        |        payment    restaurant   delivery    notification
        |        |         worker      worker      worker       worker
        |        |           |           |            |            |
        |        |           +-----------+------------+------------+
        |        |                       |
        |        |   retry_jobs + SCHEDULED outbox row (targeted,
        |        |   default exchange, header x-attempt=2/3/4)
        |        |                       |
        |        |             +---------v----------+
        |        +-------------|  Retry scheduler   | flips SCHEDULED
        |                      +---------+----------+ -> PENDING when due
        |                                |
        |                      dead-letters (exhausted / malformed)
        |                                v
        |                      quickbite.dead -> orders.dead-letter.queue
        |                      + quarantine_records ledger (SQL)
        v
   PostgreSQL remains the single source of order truth.
```

## Key boundaries

- **Flutter talks only to FastAPI.** Broker/database credentials never reach a
  client; `API_BASE_URL` is a public build parameter.
- **The API never touches RabbitMQ.** It commits the order, its history row,
  its idempotency response, and its outbox event in one transaction, then
  returns 202. Publishing is somebody else's job.
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
  transaction with the order row locked (`SELECT ... FOR UPDATE`).

## The transactional outbox

Every outgoing envelope is written to `outbox_events` **in the same
transaction** as the domain change that produced it — an accepted order can
never exist without its event, and vice versa.

The outbox dispatcher (single logical publisher, safe to scale — rows are
claimed under `FOR UPDATE SKIP LOCKED`) polls due `PENDING` rows and
publishes each with:

- **publisher confirms** — the broker explicitly acknowledges the frame;
- **`mandatory=True` + `on_return_raises=True`** — a routing key with no
  matching binding raises `PublishError` instead of silently "succeeding";
  the row stays `PENDING` with `last_error` recorded and is retried on the
  next poll.

Only after an unambiguous confirm does the row become `SENT`. A crash between
publish and commit re-publishes later — delivery is **at-least-once**, and
consumers deduplicate with `processed_events`.

## Consumer processing sequence

Every delivery runs through `workers/runtime.py`:

1. **Validate the envelope** — unparseable/invalid bodies are quarantined
   immediately (never retried; a bad payload will still be bad later).
2. **Simulate stage latency before the transaction** — row locks are never
   held during a sleep.
3. **Lock the order row** (`SELECT ... FOR UPDATE`) so concurrent deliveries
   for the same order serialize.
4. **Check `processed_events`** (`consumer_name`, `event_id`) — a duplicate
   is acknowledged without re-applying anything.
5. **Classify the current state** — already past this event ⇒ `stale` no-op
   ack; prerequisite not yet visible ⇒ bounded retry (out-of-order
   protection).
6. **Apply stage effect + status transition + follow-up outbox event in one
   transaction**, record `processed_events`, commit, ack.

Failure classes: unexpected database errors and handler bugs are **rolled
back and nacked (requeued), never acknowledged away**.

## Bounded retries (1 + 3, ≈ 2/10/30 s)

On a transient failure the worker persists, in one transaction:

- a `retry_jobs` row (unique per consumer/event/attempt — idempotent
  scheduling), and
- a **`SCHEDULED` outbox row** targeting the *same* queue through the
  default exchange, carrying the original envelope verbatim (same immutable
  `event_id`) plus `retry_attempt`, which the dispatcher publishes as the
  **`x-attempt` AMQP header**.

then acknowledges the original delivery — the retry is durable before the
original is gone. The **retry scheduler** flips due `SCHEDULED` rows to
`PENDING`; the dispatcher publishes them like any other event and marks the
retry job `PUBLISHED` after the confirm.

After attempt 1 + `RETRY_MAX_ATTEMPTS` (default 3, delays 2/10/30 s), the
event is **quarantined**: a `quarantine_records` ledger row, a dead-letter
copy published to `quickbite.dead` → `orders.dead-letter.queue`, and — where
appropriate — a terminal order transition (`PAYMENT_FAILED` + the
`order.payment.failed` event, or `FAILED` + `order.failed`), all in one
transaction. Notification-stage failures quarantine without touching the
order.

## Readiness semantics

`/health/ready` requires PostgreSQL only. Broker downtime does **not** make
the API unready: accepted orders wait safely in the outbox and drain when
RabbitMQ returns (the payload still reports broker status for operators).

## Testing against real infrastructure

`uv run pytest` provisions an **isolated database (`quickbite_test`) and
RabbitMQ vhost (`quickbite_test`)** so the suite exercises the real
dispatcher/consumers without racing a developer's running compose workers.
Retry delays are accelerated to 0.5/1/1.5 s in tests; the compose stack
runs the production 2/10/30 s schedule.

## Implemented milestones

- **M1** — config validation, CORS allow-list, request-id correlation,
  `/health/*`, auth (`login`, `me`), 14 tables via Alembic
  (`0d0a1aac259d_initial_schema`), repeatable seed, compose stack.
- **M2** — restaurant/menu reads, idempotent checkout (202 + `Location`,
  fast-path replay, 409 on payload change), order reads/history/
  notifications, admin orders + summary, outbox writes in the same
  transaction.
- **M3** — RabbitMQ topology (`quickbite.orders` topic with `order.#`
  notification binding, `quickbite.dead`), confirmed outbox dispatcher,
  four stage workers, transactional retries (`retry_jobs` + scheduler),
  `processed_events` dedup, quarantine + dead-letter path, and the
  integration suite (`tests/test_pipeline_m3.py`).
