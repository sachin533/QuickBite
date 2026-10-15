# Pinned versions

Lockfiles are committed (`backend/uv.lock`); no floating `latest` tags are used.

## Container images

| Image | Tag | Purpose |
|---|---|---|
| `postgres` | `16.4-alpine` | authoritative order store |
| `rabbitmq` | `4.1-management-alpine` | broker + management UI |
| `python` | `3.12.8-slim-bookworm` | backend/worker base image |
| `nginx` | `1.27-alpine` | Flutter web host (Milestone 7) |
| `ghcr.io/astral-sh/uv` | `0.10.6` | dependency installer in Docker build |

## Python (resolved by `uv.lock`)

| Package | Version |
|---|---|
| fastapi | 0.143.1 |
| starlette | 1.8.0 |
| uvicorn | 0.54.0 |
| pydantic | 2.14.1 |
| pydantic-settings | 2.16.0 |
| email-validator | 2.3.0 |
| sqlalchemy | 2.1.4 |
| alembic | 1.20.0 |
| psycopg (v3) | 3.3.6 |
| pyjwt | 2.15.1 |
| bcrypt | 4.3.0 |
| aio-pika | 9.6.2 |
| pytest | 8.4.2 |
| httpx | 0.28.1 |

## Host tooling (documented as tested)

- Docker 29.8.1, Docker Compose v5.5.1
- Python 3.12.8 (local), uv 0.10.6
- Flutter 3.47.7 (SDK at `E:\flutter`, installed via SHA256-verified archive;
  `flutter` added to the user `PATH`)
- Windows 11 host

## Reproduce

```powershell
cd backend
uv sync --frozen        # exact versions from uv.lock
uv pip list --format=freeze
```
