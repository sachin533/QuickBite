# QuickBite — Full-Stack Food Delivery Order Processing System

FastAPI + RabbitMQ + PostgreSQL + Flutter (Web / Android / iOS).

> **Status: Milestone 1 complete** — backend scaffold, schema/state machine,
> Compose stack, migrations, seeded accounts/menu, authentication.
> Milestones 2–7 (checkout idempotency, outbox + workers, retries/quarantine,
> Flutter client, tests, load/demo) are pending.

## Prerequisites

| Tool | Version used | Notes |
|---|---|---|
| Docker / Docker Compose | 29.8.1 / v5.5.1 | runs Postgres, RabbitMQ, API |
| Python | 3.12.8 | local development and tests |
| uv | 0.10.6 | dependency + lockfile manager (`pip` works too) |
| Flutter | *not installed yet* | required from Milestone 5 (Web/Android/iOS) |

## Clean install (from an empty checkout)

```powershell
# 1. Configure the environment (never commit .env)
Copy-Item .env.example .env
#    then set JWT_SECRET in .env to >=32 random chars:
py -c "import secrets; print(secrets.token_urlsafe(48))"

# 2. Build and start Postgres, RabbitMQ, migrations, seed, API
docker compose up -d --build

# 3. Verify
Invoke-RestMethod http://localhost:8000/health/ready
```

`migrate` (Alembic) and `seed` are one-shot services that run before the API
starts — deliberate, repeatable steps rather than competing startup jobs.

### Re-run migrations / seed at any time

```powershell
docker compose run --rm migrate     # alembic upgrade head
docker compose run --rm seed        # idempotent seed (use --reset to wipe)
```

### Local development without Docker for the API

```powershell
cd backend
uv sync                              # creates .venv from uv.lock
uv run alembic upgrade head
uv run python -m app.seed
uv run uvicorn app.main:app --reload --port 8000
uv run pytest                        # expects Postgres on localhost:5432
```

## Test accounts (seeded, fictional)

| Role | Email | Password |
|---|---|---|
| customer | `maya@quickbite.dev` | `demo12345` |
| customer | `arjun@quickbite.dev` | `demo12345` |
| admin | `admin@quickbite.dev` | `admin12345` |

## URLs

| Service | Address |
|---|---|
| API | http://localhost:8000 |
| OpenAPI docs | http://localhost:8000/docs |
| Health | http://localhost:8000/health/live · /health/ready |
| RabbitMQ management | http://localhost:15672 (`guest`/`guest`) |
| PostgreSQL | localhost:5432 (`quickbite`/`quickbite`) |

> Container service names (`api`, `postgres`, `rabbitmq`) are Compose-network
> addresses, never browser/device addresses.

### Flutter API base URL (used from Milestone 5)

```powershell
flutter run -d chrome        --dart-define=API_BASE_URL=http://localhost:8000
flutter run -d <android>     --dart-define=API_BASE_URL=http://10.0.2.2:8000
flutter run -d <ios-sim>     --dart-define=API_BASE_URL=http://localhost:8000
flutter build web            --dart-define=API_BASE_URL=http://localhost:8000
flutter build apk            --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

Physical devices use your machine's LAN IP (e.g. `http://192.168.1.10:8000`);
the development API must bind to `0.0.0.0` for that.

## Retry policy (documented default)

1 initial attempt + **3 delayed retries ≈ 2 s, 10 s, 30 s**, then quarantine.
Configured by `RETRY_MAX_ATTEMPTS` and `RETRY_DELAYS_SECONDS` in `.env`.
Implemented in Milestone 4.

## API conventions

- All domain routes are prefixed `/api/v1`; OpenAPI published at `/api/v1/openapi.json`.
- Money is **integer minor units** (`1250` = INR 12.50, `currency: "INR"`).
- Pagination: `page` (≥1) and `page_size` (≤100); lists return
  `items`, `page`, `page_size`, `total`.
- Errors always return `{code, message, details, request_id}`; the same
  `request_id` is echoed in the `X-Request-ID` response header and logs.
- Timestamps are UTC ISO-8601 with timezone information.

## Repository layout

```
backend/app/api/        routes, dependencies, error envelopes
backend/app/domain/     enums, state machine, ids, money
backend/app/schemas/    Pydantic request/response models
backend/app/models.py   SQLAlchemy models (14 tables)
backend/migrations/     Alembic migrations
backend/tests/          pytest suites (real Postgres)
infra/                  Dockerfiles
compose.yaml            postgres, rabbitmq, migrate, seed, api
docs/                   architecture + pinned versions
scripts/                (later) seed, load, failure demos
frontend/               (later) Flutter project
```

## Configuration

Copy `.env.example` → `.env` (root for Compose interpolation, `backend/.env`
for local `uvicorn`). Validation runs at startup: the service refuses to boot
with a short/missing `JWT_SECRET`, and production additionally rejects
wildcard CORS and default broker credentials.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `port is already allocated` (5432/5672/8000) | another local Postgres/RabbitMQ/API is running — stop it or edit `compose.yaml` ports |
| `JWT_SECRET must be set...` | your `.env` still has the placeholder value |
| `/health/ready` = 503 | `docker compose ps`; Postgres is the only *required* dependency |
| `/health/ready` reports `broker: false` | RabbitMQ is down; committed orders are safe in the outbox (by design) |
| Tests fail to connect | start the stack first: `docker compose up -d` |
| Re-seed from scratch | `docker compose run --rm seed --reset` (deletes orders/users/menus) |
