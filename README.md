# Docker A2A Hermes Agent Gateway

A container image and `docker compose` stack that runs the
[**SilvaEngine Gateway**](https://github.com/ideabosque/silvaengine_gateway) with
**only** the [**a2a_daemon_engine**](https://github.com/ideabosque/a2a_daemon_engine)
module registered — exposing the native **Agent-to-Agent (A2A)** protocol surface
(JSON-RPC 2.0, GraphQL, SSE, Agent Card) and bridging A2A tasks to a
[Hermes Agent](https://hermes-agent.nousresearch.com) (Nous Research) API Server
instance over HTTP + SSE. State persists to a bundled **PostgreSQL** backend
(DynamoDB is not supported by this image).

Both `silvaengine_gateway` and `a2a_daemon_engine` are **pip-installed from git
into the image** (no host source mount). The image is generic and fully
env-driven — no secrets are baked in.

Modeled on `docker-silvaengine-gateway` (build / supervisor / SSH-key install)
and `docker-hermes-agent` (the optional Hermes sibling service).

---

## 📑 Contents

- [What you get](#-what-you-get)
- [Architecture](#-architecture)
- [Request lifecycle](#-request-lifecycle)
- [Repository layout](#-repository-layout)
- [Quick start](#-quick-start)
- [Using docker compose](#-using-docker-compose)
- [Ports](#-ports)
- [Volumes & persisted state](#-volumes--persisted-state)
- [Configuration reference](#️-configuration-reference)
- [Using the A2A surface](#-using-the-a2a-surface)
- [Persistence & multi-tenancy](#-persistence--multi-tenancy)
- [Image internals](#-image-internals)
- [Make targets](#️-make-targets)
- [Test scripts](#-test-scripts)
- [Operations](#-operations)
- [Security notes](#-security-notes)
- [Known limitations](#-known-limitations)
- [Troubleshooting](#-troubleshooting)
- [License](#-license)

---

## ✨ What you get

| Protocol | Route (per registered module) | Auth | Notes |
|---|---|---|---|
| GraphQL | `POST /{ep}/a2a_core_graphql` | ✅ | A2A core queries/mutations (agents, tasks, messages, settings) |
| JSON-RPC 2.0 | `POST /{ep}/a2a` | ✅ | A2A protocol: `message/send`, `tasks/get`, `tasks/cancel`, `tasks/list`, … |
| SSE (stream) | `GET /{ep}/a2a_sse` | ✅ | Long-lived per-partition A2A task event stream |
| SSE (push) | `POST /{ep}/a2a_sse` | ✅ | JSON-RPC message + push to connected SSE clients |
| Agent Card | `GET /{ep}/.well-known/agent-card.json` | ❌ public | A2A discovery document (`Part-Id` header still required) |
| Health | `GET /health` | ❌ public | Used by the container healthcheck |
| Auth | `POST /auth/token`, `GET /me` | ❌ / ✅ | Local JWT or AWS Cognito |

`{ep}` is the `endpoint_id` (path segment, `a2a` by default); the tenant
partition id is supplied via the `Part-Id` request header. Together they form
`partition_key = "{endpoint_id}#{Part-Id}"` (e.g. `a2a#default`).

Routes are declared by the A2A-only [`routes.yaml`](routes.yaml) baked into the
image and bind-mounted from the host by compose (edit + restart, no rebuild).

---

## 🏗️ Architecture

```
                ┌─────────────────────────────────────────────────┐
   A2A client   │  a2a-gateway (silvaengine_gateway + a2a_daemon)  │   Hermes API
   ───────────▶ │  /{ep}/a2a  (JSON-RPC)                          │   ──────────▶
  (JSON-RPC/SSE)│  /{ep}/a2a_sse (SSE)                            │   HTTP + SSE
                │  /{ep}/a2a_core_graphql                         │
                │  /{ep}/.well-known/agent-card.json              │
                └─────────────────────────────────────────────────┘
                       │                              │
                       │ HermesAgentHandler           │ SQLAlchemy (psycopg2)
                       ▼ HERMES_API_URL               ▼ PG_HOST:PG_PORT
       ┌───────────────────────────────┐   ┌─────────────────────────────┐
       │ hermes (nousresearch/…)       │   │ postgres  [optional]        │
       │ OpenAI-compatible API server  │   │ a2a_agents / a2a_tasks /    │
       │ + web dashboard    [optional] │   │ a2a_messages / a2a_settings │
       └───────────────────────────────┘   └─────────────────────────────┘
```

The gateway is the only always-on service. Both **Hermes** and **PostgreSQL**
are profile-gated siblings — bundle them for a self-contained stack, or turn
the profiles off and point `HERMES_API_URL` / `PG_*` at external instances.

---

## 🔄 Request lifecycle

A single `message/send` with `stream=true` traverses:

```
1. Client         POST /{ep}/a2a  {jsonrpc, method:"message/send", params}
                  Headers: Authorization: Bearer <jwt>, Part-Id: <tenant>
2. Gateway        auth (local JWT / Cognito) → route match from routes.yaml
                  → partition_key = "{ep}#{Part-Id}"
3. a2a_daemon     dispatch_a2a → A2ADaemonExecutor
                  → resolve_agent(): agent metadata (DB) > setting dict > Config (env)
4. Handler        HermesAgentHandler (A2A_AI_AGENT_MODULE / _CLASS)
5. Hermes         POST {HERMES_API_URL}/v1/runs   (Bearer HERMES_API_KEY)
                  GET  {HERMES_API_URL}/v1/runs/{id}/events   (SSE)
6. Broadcast      token chunks → subscribers on GET /{ep}/a2a_sse
7. Persist        task + messages written to PostgreSQL (a2a_* tables, RLS-scoped)
8. Response       accumulated reply also returned in the HTTP JSON-RPC result
```

Step 8 matters: even when streaming, the HTTP response carries the full reply,
so a client that misses SSE frames can still fall back to it (this is exactly
what `test_hermes_sse_live.py` step 06 verifies).

---

## 📂 Repository layout

```text
.
├── Dockerfile               # Python 3.12-slim + uv + supervisor build
├── docker-compose.yml       # a2a-gateway + optional hermes / postgres siblings
├── requirements.txt         # third-party deps + shared SilvaEngine libs (git over HTTPS)
├── requirements-modules.txt # silvaengine_gateway + a2a_daemon_engine (--no-deps, git over HTTPS)
├── routes.yaml              # A2A-only route manifest (baked in + bind-mounted)
├── supervisord.conf         # single gateway process under supervisor
├── .env.example             # environment template — copy to .env
├── .dockerignore            # keeps build context lean (requirements/routes NOT ignored)
├── Makefile                 # convenience targets
├── pyproject.toml           # project metadata + ruff/black config (line-length 88)
├── a2a_test_utils.py        # shared test helpers (.env load, JWT mint, JSON-RPC)
├── test_hermes_hello.py     # smoke: non-streaming message/send
├── test_hermes_hello_sse.py # smoke: streaming over SSE
├── test_hermes_gateway_live.py # E2E suite: 9 checks (health → failure path)
├── test_hermes_sse_live.py  # E2E suite: 6 checks (SSE streaming pipeline)
├── test_hermes_chatbot.py   # interactive REPL with live SSE streaming
├── data/                    # persisted gateway state ➜ /app/data
├── logs/                    # supervisor & gateway logs ➜ /var/log/supervisor
├── postgres_data/           # bundled PostgreSQL data dir (profile: postgres)
├── postgres_logs/           # bundled PostgreSQL logs (profile: postgres)
└── www/                     # bundled Hermes bind-mounts (hermes data / projects)
```

`data/`, `logs/`, `postgres_data/`, `postgres_logs/`, `www/` and `.env` are
gitignored — they hold runtime state and secrets.

---

## 🚀 Quick start

For the fully bundled stack (gateway + PostgreSQL + Hermes):

```bash
cp .env.example .env

# Fill in the required values (see "Step 1 — Configure" for the full list):
#   JWT_SECRET_KEY, ADMIN_PASSWORD, API_SERVER_KEY, HERMES_API_KEY (= API_SERVER_KEY),
#   HERMES_MODEL_PROVIDER + the matching provider key, HERMES_MODEL

mkdir -p www/hermes www/projects

DOCKER_BUILDKIT=1 docker compose build
docker compose up -d           # COMPOSE_PROFILES=postgres,hermes is the .env default

docker compose ps              # wait for (healthy)
curl -f http://localhost:8765/health

pip install requests
python test_hermes_hello.py    # end-to-end smoke test
```

---

## 🚢 Using docker compose

The stack has **one always-on service** and **two optional profile-gated
siblings**:

| Service | Container name (default) | Always on? | Profile | Purpose |
|---|---|---|---|---|
| `a2a-gateway` | `a2a-hermes-gateway` | ✅ yes | — | SilvaEngine Gateway (A2A-only routes) + Hermes bridge |
| `postgres` | `a2a-postgres` | optional | `postgres` | Bundled PostgreSQL persistence backend |
| `hermes` | `container-hermes` | optional | `hermes` | Bundled Nous Research Hermes Agent (OpenAI-compatible API + dashboard) |

PostgreSQL is the **sole** persistence backend (`db_backend=postgresql` is
forced in the image — no DynamoDB). The bundled `postgres` service is optional
only in the sense that you may instead point `PG_*` at an external Postgres.

The bundled `hermes` service is optional — you may instead point
`HERMES_API_URL` at an external Hermes API Server.

The gateway `depends_on` both siblings with `condition: service_healthy` and
`required: false`, so it waits for whichever profiles are active and starts
anyway when they are off.

### ⚠️ Editing `.env` (read this first)

Docker compose's `env_file` parser **does not strip inline comments**. A line
like
```
HERMES_API_KEY=hermes-local-key   # token for Hermes
```
sets `HERMES_API_KEY` to the literal string
`hermes-local-key   # token for Hermes` (comment included), which silently
breaks authentication. Rules:

- Put **nothing after the value** on any `KEY=value` line.
- Put notes on their own `#` comment lines **above** the variable.
- Leading/trailing whitespace around the value is preserved — keep it tight
  (`KEY=value`, not `KEY=  value  `).

### Step 1 — Configure

```bash
cp .env.example .env
```

Then edit `.env`. The minimum you must set:

| Variable | What to set |
|---|---|
| `JWT_SECRET_KEY` | A random string (e.g. `openssl rand -hex 32`) |
| `ADMIN_PASSWORD` | A password for the local admin user |
| `COMPOSE_PROFILES` | Which bundled siblings to start (see below) |
| `API_SERVER_KEY` | A random string for the bundled Hermes (e.g. `openssl rand -hex 32`) |
| `HERMES_API_KEY` | **Must equal** `API_SERVER_KEY` (Hermes API server token) |
| `HERMES_MODEL_PROVIDER` + a provider key | e.g. `anthropic` + `ANTHROPIC_API_KEY`, or `custom` + `OLLAMA_API_KEY` for Ollama Cloud |
| `HERMES_MODEL` | The model id for the chosen provider |

`COMPOSE_PROFILES` is the single switch for both siblings (comma-separated):

| Value | Services started |
|---|---|
| `COMPOSE_PROFILES=` (empty) | gateway only (external Postgres + external Hermes) |
| `COMPOSE_PROFILES=postgres` | gateway + bundled Postgres |
| `COMPOSE_PROFILES=hermes` | gateway + bundled Hermes (external Postgres) |
| `COMPOSE_PROFILES=postgres,hermes` | gateway + bundled Postgres **and** Hermes (default) |

When a sibling is bundled, keep its host reference pointed at the service
name: `PG_HOST=postgres` and `HERMES_API_URL=http://hermes:<API_SERVER_PORT>`.
When a sibling is external, point those at your own instance (e.g.
`PG_HOST=host.docker.internal`, `HERMES_API_URL=http://host.docker.internal:8642`).

> **Note on `HERMES_MODEL`.** The name appears in two roles: the A2A bridge
> sends it to Hermes as the model id (`HERMES_MODEL=hermes-agent` in the bridge
> section), and the bundled Hermes service uses it as its own default profile
> model (`HERMES_MODEL=claude-opus-4-8`). They are the *same* env var — the last
> assignment in `.env` wins for both. When running the bundled Hermes, set it to
> the provider model id that Hermes should use.

### Step 2 — Create the Hermes bind-mount directories (bundled Hermes only)

The bundled Hermes Agent bind-mounts two host directories:

```bash
mkdir -p www/hermes www/projects
```

`www/hermes` (`HERMES_DATA_FOLDER`) → `/opt/data` is all Hermes state;
`www/projects` (`PROJECTS_FOLDER`) → `/opt/projects` is its workspace.

### Step 3 — Build

`silvaengine_gateway`, `a2a_daemon_engine`, and the shared SilvaEngine
libraries are cloned from public GitHub repos under `ideabosque` over
`git+https` — no credentials or SSH deploy key needed.

```bash
DOCKER_BUILDKIT=1 docker compose build

# Force a fresh pull of the git modules (after an upstream change):
DOCKER_BUILDKIT=1 docker compose build --no-cache
```

BuildKit is required (Docker Engine 23+ enables it by default) — the Dockerfile
uses `RUN --mount`, which older builders do not understand.

### Step 4 — Start the stack

You can let `.env`'s `COMPOSE_PROFILES` drive which services come up, or pass
`--profile` flags explicitly on the command line.

```bash
# Start per .env (recommended — .env already sets COMPOSE_PROFILES):
docker compose up -d

# Or start specific profiles explicitly (adds to whatever .env selected):
docker compose --profile postgres --profile hermes up -d

# Gateway only, ignoring .env profiles:
COMPOSE_PROFILES= docker compose up -d a2a-gateway
```

Wait for the gateway to become healthy:

```bash
docker compose ps
# a2a-hermes-gateway   Up X seconds (healthy)
# a2a-postgres         Up X seconds (healthy)   (if postgres profile)
# container-hermes     Up X seconds (healthy)   (if hermes profile)
```

Healthcheck timings: the gateway allows a 40 s `start_period` then probes
`/health` every 30 s (3 retries); Hermes allows 60 s and probes its own
`/health`; Postgres uses `pg_isready` every 10 s (5 retries).

### Step 5 — Verify

```bash
make health                  # curl http://localhost:8765/health  -> 200 OK
make logs                    # tail combined logs
make gateway-logs            # tail the gateway process log (supervisor)
make status                  # supervisor process status
```

### Step 6 — Use the A2A surface

See [Using the A2A surface](#-using-the-a2a-surface) below for the full
protocol reference, or run `python test_hermes_hello.py` for an instant
end-to-end check.

---

## 🔌 Ports

| Service | Host var (default) | Container var (default) | What it serves |
|---|---|---|---|
| `a2a-gateway` | `CONTAINER_PORT` (`8765`) | `GATEWAY_PORT` (`8765`) | A2A JSON-RPC / GraphQL / SSE / auth / health |
| `hermes` | `HERMES_GATEWAY_PORT` (`8642`) | `API_SERVER_PORT` (`8642`) | OpenAI-compatible API server + `/health` |
| `hermes` | `HERMES_DASHBOARD_PORT` (`9119`) | `HERMES_DASHBOARD_PORT` (`9119`) | Web dashboard (only when `HERMES_DASHBOARD=1`) |
| `postgres` | `POSTGRES_PORT` (`5432`) | `5432` | PostgreSQL |

The gateway binds `GATEWAY_HOST` (`0.0.0.0`) inside the container. Host and
container ports are independent — change `CONTAINER_PORT` alone to resolve a
host-side conflict without touching the app config.

> The Dockerfile's `EXPOSE 8000` is documentation-only and does not match the
> `8765` default; compose publishes ports explicitly, so it has no runtime
> effect.

---

## 💾 Volumes & persisted state

| Host path (var) | Container path | Service | Contents |
|---|---|---|---|
| `./logs` | `/var/log/supervisor` | gateway | `supervisord.log`, `silvaengine-gateway.log` (50 MB × 10 rotation) |
| `./data` | `/app/data` | gateway | Gateway state; optional `users.json` for `LOCAL_USER_FILE` |
| `./routes.yaml` (`GATEWAY_ROUTES_HOST_FILE`) | `/app/routes.yaml` (ro) | gateway | Route manifest — edit + restart, no rebuild |
| `./postgres_data` (`POSTGRES_DATA_PATH`) | `/var/lib/postgresql/data` | postgres | PGDATA (`/pgdata` subdir) |
| `./postgres_logs` (`POSTGRES_LOG_PATH`) | `/var/log/postgresql` | postgres | `postgresql-YYYY-MM-DD.log` |
| `./www/hermes` (`HERMES_DATA_FOLDER`) | `/opt/data` | hermes | All Hermes state |
| `./www/projects` (`PROJECTS_FOLDER`) | `/opt/projects` | hermes | Hermes workspace |
| `/var/run/docker.sock` (`DOCKER_SOCK`) | `/var/run/docker.sock` | hermes | Host Docker access — see [Security notes](#-security-notes) |

These are bind mounts, not named volumes, so `docker compose down -v` does not
erase them — delete the host directories to reset state.

---

## ⚙️ Configuration reference

All configuration is environment-driven via `.env` (copied from
`.env.example`). Compose feeds the whole file to the gateway, which forwards
module settings to `a2a_daemon_engine`'s `Config.initialize()`.

### Gateway — server

| Variable | Default | Purpose |
|---|---|---|
| `CONTAINER_PORT` | `8765` | Published host port |
| `GATEWAY_PORT` | `8765` | In-container uvicorn bind port |
| `GATEWAY_HOST` | `0.0.0.0` | In-container bind address |
| `GATEWAY_WORKERS` | `1` | Worker processes (>1 needs shared backends — see [Scaling](#scaling-gateway_workers--1)) |
| `GATEWAY_DISPATCH_WORKERS` | `32` | Sync dispatch thread-pool size |
| `GATEWAY_CORS_ORIGINS` | `*` | `*` = any origin **without** credentials; a comma-separated list also allows credentials |
| `GATEWAY_ROUTES_CONFIG_PATH` | `/app/routes.yaml` | Route manifest path inside the container (set in the Dockerfile) |
| `GATEWAY_ROUTES_HOST_FILE` | `./routes.yaml` | Host file compose mounts over that path |

### Gateway — auth

| Variable | Default | Purpose |
|---|---|---|
| `GATEWAY_AUTH_PROVIDER` | `local` | `local` or `cognito` |
| `JWT_SECRET_KEY` | — | Local JWT signing secret (**change it**) |
| `JWT_ALGORITHM` | `HS256` | Signing algorithm |
| `ACCESS_TOKEN_EXP` | `15` | Token lifetime, minutes |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | `admin` / `change-me` | Bootstrap local admin |
| `ADMIN_STATIC_TOKEN` | unset | Optional pre-minted permanent admin token (test scripts prefer it) |
| `LOCAL_USER_FILE` | unset | Path to a `users.json` in `/app/data` for additional local users |
| `COGNITO_USER_POOL_ID` | — | Cognito pool (only when `GATEWAY_AUTH_PROVIDER=cognito`) |
| `COGNITO_APP_CLIENT_ID` / `COGNITO_APP_SECRET` | — | Cognito app client |
| `COGNITO_JWKS_URL` | — | JWKS endpoint for token verification |

### Gateway — shared stores

Required only when `GATEWAY_WORKERS > 1`.

| Variable | Default | Purpose |
|---|---|---|
| `GATEWAY_TASK_BACKEND` | `memory` | `memory` or `dynamodb` |
| `GATEWAY_TASK_TTL` | `3600` | Task record TTL, seconds |
| `GATEWAY_RATE_LIMIT_BACKEND` | `memory` | `memory` or `dynamodb` |
| `GATEWAY_RATE_LIMIT` | `500` | Requests per window |
| `GATEWAY_RATE_WINDOW` | `60` | Window length, seconds |

### PostgreSQL (persistence)

| Variable | Default | Purpose |
|---|---|---|
| `db_backend` | `postgresql` (forced in image) | PostgreSQL is the sole backend — no DynamoDB |
| `PG_HOST` | `postgres` | Host (`postgres` when bundled) |
| `PG_PORT` | `5432` | Port |
| `PG_USER` / `PG_PASSWORD` / `PG_DB` | `silvaengine` ×3 | Credentials + database |
| `DATABASE_URL` | unset | Overrides `PG_*` (used by alembic migrations) when set |
| `initialize_tables` | `1` | Auto-create tables + RLS policies on startup |

### Bundled PostgreSQL sibling (profile `postgres`)

`POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` must match
`PG_USER` / `PG_PASSWORD` / `PG_DB` above.

| Variable | Default | Purpose |
|---|---|---|
| `POSTGRES_VERSION` | `17-alpine` | Image tag |
| `POSTGRES_CONTAINER_NAME` | `a2a-postgres` | Container name |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `silvaengine` ×3 | Bootstrap credentials |
| `POSTGRES_PORT` | `5432` | Published host port |
| `POSTGRES_DATA_PATH` / `POSTGRES_LOG_PATH` | `./postgres_data` / `./postgres_logs` | Host bind mounts |
| `LOG_STATEMENT` | `none` | `none` \| `ddl` \| `mod` \| `all` |
| `LOG_MIN_DURATION` | `1000` | Log queries slower than N ms (`-1` disables) |

### Hermes bridge (a2a_daemon_engine)

| Variable | Default | Purpose |
|---|---|---|
| `HERMES_API_URL` | `http://hermes:8642` | Hermes Agent API Server base URL |
| `HERMES_API_KEY` | — | Bearer token — must equal Hermes `API_SERVER_KEY` |
| `HERMES_MODEL` | `hermes-agent` | Model id passed to Hermes |
| `HERMES_STREAM_TIMEOUT` | `300` | Hermes SSE stream timeout, seconds |
| `A2A_AI_AGENT_MODULE` | `a2a_daemon_engine.handlers.a2a_hermes_handler` | Handler module (fallback when the agent record has no metadata) |
| `A2A_AI_AGENT_CLASS` | `HermesAgentHandler` | Handler class |
| `A2A_DEFAULT_AGENT_UUID` | `a2a-hermes-agent` | Agent used when a request targets none |
| `A2A_STREAM_TIMEOUT` | `120.0` | A2A-side stream timeout, seconds |
| `A2A_STREAMING_ENABLED` | `true` | Enable streaming via SSE |

Config resolution priority (per-agent): **agent metadata (DB) > setting dict >
Config class (env vars above)**. The env-var defaults let the bridge reach
Hermes **without** a DB agent record — see `a2a_ai_agent_utility.resolve_agent()`.

### Bundled Hermes sibling (profile `hermes`)

| Variable | Default | Purpose |
|---|---|---|
| `HERMES_IMAGE` / `HERMES_TAG` | `nousresearch/hermes-agent` / `latest` | Image |
| `HERMES_CONTAINER_NAME` | `container-hermes` | Container name |
| `HERMES_COMMAND` | `gateway run` | Container command |
| `API_SERVER_ENABLED` | `true` | Enable the OpenAI-compatible API server |
| `API_SERVER_HOST` / `API_SERVER_PORT` | `0.0.0.0` / `8642` | API server bind |
| `API_SERVER_KEY` | — | API server bearer token (**= `HERMES_API_KEY`**) |
| `API_SERVER_CORS_ORIGINS` | `*` | CORS allow-list |
| `HERMES_MODEL_PROVIDER` | `anthropic` | Selects which provider key is used |
| `HERMES_MODEL` | `claude-opus-4-8` | Default profile model |
| `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `OPENROUTER_API_KEY` / `NOUS_API_KEY` | — | Provider keys |
| `OLLAMA_API_KEY` / `OLLAMA_BASE_URL` | — / `https://ollama.com/v1` | Ollama Cloud (custom OpenAI-compatible endpoint) |
| `HERMES_DASHBOARD` | `1` | Enable the web dashboard |
| `HERMES_DASHBOARD_HOST` / `HERMES_DASHBOARD_PORT` | `0.0.0.0` / `9119` | Dashboard bind |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` / `_PASSWORD` / `_SECRET` | — | Dashboard basic auth (**set these if the port is reachable**) |
| `HERMES_DATA_FOLDER` / `PROJECTS_FOLDER` | `./www/hermes` / `./www/projects` | Host bind mounts |
| `DOCKER_SOCK` | `/var/run/docker.sock` | Docker socket passed into the container |
| `HERMES_UID` / `HERMES_GID` | `1000` / `1000` | In-container user |
| `HERMES_SHM_SIZE` | `1g` | Shared memory size |
| `HERMES_MEMORY_LIMIT` / `HERMES_CPU_LIMIT` | `4G` / `2.0` | Resource limits |
| `TELEGRAM_BOT_TOKEN` / `DISCORD_BOT_TOKEN` / `SLACK_BOT_TOKEN` | — | Messaging gateway tokens (default profile only) |

### Scaling (`GATEWAY_WORKERS > 1`)

In-memory task state, rate-limit counters, and the SSE client registry are
**per-process**. With more than one worker, switch to shared backends
(`GATEWAY_TASK_BACKEND=dynamodb`, `GATEWAY_RATE_LIMIT_BACKEND=dynamodb`, plus
`region_name` / `aws_*` credentials) and use sticky sessions for SSE.

---

## 📡 Using the A2A surface

### 1. Get a token

```bash
TOKEN=$(curl -s -X POST http://localhost:8765/auth/token \
  -d "username=admin&password=$ADMIN_PASSWORD" \
  | python -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

curl -H "Authorization: Bearer $TOKEN" http://localhost:8765/me
```

Tokens expire after `ACCESS_TOKEN_EXP` minutes. For long-lived automation, set
`ADMIN_STATIC_TOKEN` in `.env` and use it directly. The claim set the test
helpers mint is `{username, role, perm, iat}` signed HS256 with `JWT_SECRET_KEY`
— see `mint_jwt()` in [a2a_test_utils.py](a2a_test_utils.py).

### 2. Every request needs `Part-Id`

```
Authorization: Bearer <jwt>       (except the agent card and /health)
Part-Id: default                  (always — including the agent card)
Content-Type: application/json
```

### 3. JSON-RPC methods

`POST /{ep}/a2a` with a standard JSON-RPC 2.0 envelope
(`{"jsonrpc":"2.0","id":…,"method":…,"params":…}`):

| Method | `params` | Returns |
|---|---|---|
| `message/send` | `{message, metadata}` | Task result incl. reply parts + status |
| `tasks/get` | `{id, metadata:{agent_uuid}}` | Task record + status |
| `tasks/list` | `{metadata:{agent_uuid}}` | `{tasks: [...]}` |
| `tasks/cancel` | `{id, metadata:{agent_uuid}}` | Task in `CANCELED` state (or an error if it already finished) |

The `message/send` params shape used by the harnesses:

```json
{
  "message": {
    "role": "ROLE_USER",
    "parts": [{ "text": "Say hello from A2A" }]
  },
  "metadata": {
    "operation": "task_execution",
    "agent_uuid": "a2a-hermes-agent",
    "stream": true,
    "task_data": { "task_id": "my-task-001", "task_type": "hermes_test" },
    "system_prompt": "You are a concise assistant.",
    "conversation_history": []
  }
}
```

| `metadata` key | Required | Meaning |
|---|---|---|
| `operation` | ✅ | `task_execution` for agent runs |
| `agent_uuid` | ✅ | Target agent; defaults to `A2A_DEFAULT_AGENT_UUID` |
| `stream` | — | `true` broadcasts token chunks to `/{ep}/a2a_sse` |
| `task_data.task_id` | — | Caller-supplied id; used by `tasks/get` / `tasks/cancel` |
| `task_data.task_type` | — | Free-form label for grouping |
| `system_prompt` | — | Per-request system prompt |
| `conversation_history` | — | Prior turns for multi-turn context |

Full worked example:

```bash
curl -X POST http://localhost:8765/a2a/a2a \
  -H "Authorization: Bearer $TOKEN" \
  -H "Part-Id: default" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": "1",
    "method": "message/send",
    "params": {
      "message": {"role": "ROLE_USER", "parts": [{"text": "Hello from A2A"}]},
      "metadata": {"operation": "task_execution", "agent_uuid": "a2a-hermes-agent", "stream": false}
    }
  }'
```

### 4. Agent Card discovery (public)

```bash
curl -H "Part-Id: default" \
  http://localhost:8765/a2a/.well-known/agent-card.json
```

No `Authorization` needed — but `Part-Id` still is, since the card is resolved
per partition.

### 5. A2A core GraphQL

```bash
curl -X POST http://localhost:8765/a2a/a2a_core_graphql \
  -H "Authorization: Bearer $TOKEN" \
  -H "Part-Id: default" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ ping }"}'
```

This is where agents, tasks, messages and settings are managed as records
(as opposed to the JSON-RPC protocol surface, which executes them).

### 6. SSE streaming

```bash
# Subscribe first (long-lived), then send with "stream": true from another shell
curl -N -H "Authorization: Bearer $TOKEN" \
  -H "Part-Id: default" \
  http://localhost:8765/a2a/a2a_sse
```

The stream is **per partition**, not per task — every task in
`{ep}#{Part-Id}` broadcasts to all subscribers of that partition. Order of
operations matters: connect the listener *before* sending, or early token
chunks are missed. `POST /{ep}/a2a_sse` sends a JSON-RPC message and pushes the
result to connected clients in one call.

Responses may arrive wrapped in an API-Gateway-style envelope
(`{"body": "<json string>"}`); `unwrap_response()` in
[a2a_test_utils.py](a2a_test_utils.py) handles both forms.

---

## 🗄️ Persistence & multi-tenancy

`a2a_daemon_engine` uses **literal, unprefixed** table names:

| Table | Holds |
|---|---|
| `a2a_agents` | Agent records + per-agent handler/model metadata |
| `a2a_tasks` | Task lifecycle + status |
| `a2a_messages` | Message turns per task |
| `a2a_settings` | Per-partition setting dicts |

Because the names are unprefixed, **do not share `PG_DB` with another module
that uses the same names.**

Tenant isolation uses PostgreSQL **row-level security**: the session variable
`app.tenant_id` is set to the request's `partition_key`
(`"{endpoint_id}#{Part-Id}"`), and RLS policies scope every query to it. Tables
and policies are created automatically on gateway startup when
`initialize_tables=1`.

To inspect state directly:

```bash
docker exec -it a2a-postgres psql -U silvaengine -d silvaengine -c "\dt"
docker exec -it a2a-postgres psql -U silvaengine -d silvaengine \
  -c "SELECT partition_key, count(*) FROM a2a_tasks GROUP BY 1;"
```

---

## 🧱 Image internals

| Aspect | Detail |
|---|---|
| Base | `python:3.12-slim` |
| Package manager | [`uv`](https://astral.sh/uv), venv at `/opt/venv` (first on `PATH`) |
| System packages | `supervisor`, `curl`, `git` |
| Process manager | supervisor (`nodaemon`), single program `silvaengine-gateway` |
| Entrypoint | `/opt/venv/bin/python -m silvaengine_gateway`, `cwd=/app` |
| Runtime user | `gateway` (uid 1000); supervisor starts as root and drops privileges |
| Baked env | `db_backend=postgresql`, `GATEWAY_ROUTES_CONFIG_PATH=/app/routes.yaml` |
| Logs | `/var/log/supervisor/silvaengine-gateway.log`, 50 MB × 10 backups, stderr merged |
| Restart policy | supervisor `autorestart=true`, `startsecs=10`, `stopwaitsecs=30` |

The module is invoked with `-m` rather than the packaged `silvaengine-gateway`
console script: that entry point points at `__main__:main`, which does not
exist — the module's `if __name__ == "__main__"` block is what calls
`run_gateway()`.

### Why two requirements files

`requirements.txt` installs the third-party stack (FastAPI, uvicorn, httpx,
graphene, a2a-sdk, SQLAlchemy + psycopg2, pynamodb, …) **and** the shared
SilvaEngine libraries from git. Ordering there is load-bearing:
`silvaengine_constants` must come first because `silvaengine_utility` imports it
at module load without declaring it as a dependency.

`requirements-modules.txt` then installs `silvaengine_gateway` and
`a2a_daemon_engine` with `--no-deps`, because their metadata declares sibling
engines by bare name (`knowledge_graph_engine`, `rfq_engine`,
`mcp-daemon-engine`, `ai_coordination_engine`) that are not on PyPI and are
intentionally absent from this A2A-only image.

---

## 🛠️ Make targets

| Target | Action |
|---|---|
| `make build` | Build the image |
| `make up` | Start the stack (detached) |
| `make dev` | Build + run in foreground with logs |
| `make down` | Stop & remove containers |
| `make logs` | Tail combined logs |
| `make gateway-logs` | Tail the gateway process log (supervisor) |
| `make status` | Supervisor process status |
| `make restart` | Restart the gateway process (no rebuild) |
| `make shell` | Shell into the gateway container |
| `make health` | Curl `/health` |
| `make clean` | Down + drop volumes & dangling images |
| `make rebuild` | clean → build → up |
| `make hermes-up` | `docker compose --profile hermes up -d` |
| `make hermes-down` | Stop the bundled Hermes sibling |
| `make postgres-up` | `docker compose --profile postgres up -d postgres` |
| `make postgres-down` | Stop the bundled PostgreSQL sibling |

**Make does not read `.env`.** Two variables are declared with `?=` defaults and
can be overridden from the environment:

```bash
A2A_GATEWAY_CONTAINER_NAME=my-gateway make shell    # default: a2a-hermes-gateway
CONTAINER_PORT=9000 make health                     # default: 8765
```

If you changed either value in `.env`, export it (or pass it inline as above)
before running the container-exec targets. Everything that shells out to
`docker compose` picks up `.env` normally — only the `docker exec` and `curl`
targets need this.

---

## 🧪 Test scripts

Standalone Python examination harnesses (only dependency: `requests`). They
load `./.env` from this directory, resolve or mint a gateway JWT, and talk to
the running stack. Run them from the project root after `docker compose up`.

```bash
pip install requests
```

| Script | Kind | What it does |
|---|---|---|
| [test_hermes_hello.py](test_hermes_hello.py) | smoke | Non-streaming `message/send`, prints the reply |
| [test_hermes_hello_sse.py](test_hermes_hello_sse.py) | smoke | One prompt streamed back over SSE |
| [test_hermes_gateway_live.py](test_hermes_gateway_live.py) | E2E suite | 9 checks: Hermes health, gateway health, agent card, GraphQL ping, `message/send`, `tasks/get`, `tasks/list`, `tasks/cancel`, failure path |
| [test_hermes_sse_live.py](test_hermes_sse_live.py) | E2E suite | 6 checks: health ×2, SSE connect, live token chunks, `COMPLETED` status, HTTP fallback |
| [test_hermes_chatbot.py](test_hermes_chatbot.py) | interactive | REPL against the A2A surface with live SSE streaming |
| [a2a_test_utils.py](a2a_test_utils.py) | library | Shared helpers — not run directly |

```bash
python test_hermes_hello.py
python test_hermes_hello_sse.py
python test_hermes_gateway_live.py
python test_hermes_sse_live.py
python test_hermes_chatbot.py
```

All non-interactive scripts print PASS/FAIL per step and **exit non-zero on
failure**, so they work as CI gates.

### Flags

| Flag | Scripts | Purpose |
|---|---|---|
| `--gateway-url` | all | Override `http://127.0.0.1:$CONTAINER_PORT` |
| `--hermes-url` | all | Override the host-reachable Hermes URL used for health checks |
| `--token` | all | Use a pre-minted JWT instead of resolving one |
| `--endpoint-id` | all | Default `a2a` |
| `--part-id` | all | Default `default` |
| `--agent-uuid` | all | Default `$A2A_DEFAULT_AGENT_UUID` |
| `--prompt` | all but chatbot | Override the test prompt |
| `--no-health` | hello, hello_sse, sse_live, chatbot | Skip the pre-flight health probes |
| `--timeout` | hello (300), hello_sse (200), sse_live (200) | Seconds to wait for a reply |
| `--system` | chatbot | System prompt for the session |
| `--no-sse` | chatbot | HTTP-only mode, no streaming |
| `--skip-cancel` | gateway_live | Skip step 08 (`tasks/cancel`) |

### How they resolve config

- **Gateway URL** — `http://127.0.0.1:$CONTAINER_PORT`.
- **Token** — `--token` → `ADMIN_STATIC_TOKEN` → an HS256 JWT minted from
  `JWT_SECRET_KEY` with stdlib HMAC. A non-HS256 `JWT_ALGORITHM` is not
  supported by the minter; pass `--token` or set `ADMIN_STATIC_TOKEN`.
- **Hermes URL** — `HERMES_API_URL` is the *in-container* address (e.g.
  `http://hermes:8642`), which the host cannot resolve. The helpers detect a
  bare service-name host and swap in `127.0.0.1:$HERMES_GATEWAY_PORT` for
  health checks. Actual A2A traffic still goes through the gateway.
- **`.env` parsing** — the loader strips ` #` inline comments (unlike compose),
  so a mis-formatted line may work in the tests and still break the container.

---

## 🔧 Operations

### Common commands

```bash
# Stop and remove all containers (bind-mounted data survives):
docker compose down

# Recreate the gateway after editing .env (picks up new env values):
docker compose up -d --force-recreate a2a-gateway

# Apply a routes.yaml edit (no rebuild — the file is bind-mounted):
make restart

# Start / stop a single sibling without touching the gateway:
make hermes-up      /  make hermes-down
make postgres-up    /  make postgres-down

# Tail logs for one service:
docker compose logs -f a2a-gateway
docker compose logs -f hermes
docker compose logs -f postgres

# Full clean rebuild (drops volumes + dangling images):
make rebuild
```

### After an upstream change (re-pull the git modules)

Because `silvaengine_gateway` / `a2a_daemon_engine` are pip-installed from git
at build time, an upstream change requires a rebuild with `--no-cache` so the
git layer re-clones the latest `@main`:

```bash
DOCKER_BUILDKIT=1 docker compose build --no-cache
docker compose up -d --force-recreate
```

There is no version pinning — `@main` is a moving target, so two builds on
different days can produce different images. Pin a tag or commit in
`requirements-modules.txt` if you need reproducibility.

### Resetting state

```bash
docker compose down
rm -rf postgres_data/* postgres_logs/* data/* logs/*
docker compose up -d          # initialize_tables=1 recreates tables + RLS
```

---

## 🔒 Security notes

- **Change the defaults.** `JWT_SECRET_KEY=change-me-in-production`,
  `ADMIN_PASSWORD=change-me`, and `POSTGRES_PASSWORD=silvaengine` in
  `.env.example` are placeholders, not secrets.
- **`.env` is gitignored**; `.env.example` is committed. Never put real values
  in the template.
- **No credentials in the image** — the modules are cloned from public repos at
  build time, and nothing about the build is secret-bearing.
- **The gateway runs as non-root** (`gateway`, uid 1000).
- **CORS**: `GATEWAY_CORS_ORIGINS=*` allows any origin *without* credentials.
  Wildcard and credentials are mutually exclusive per spec — set an explicit
  list if you need cookies/credentials.
- **The bundled Hermes mounts the host Docker socket** (`/var/run/docker.sock`).
  That is effectively root on the host for anything inside that container. Only
  run the `hermes` profile on a host you control, and remove the mount if the
  agent does not need to launch containers.
- **The Hermes dashboard defaults to enabled** (`HERMES_DASHBOARD=1`) on port
  `9119` with **empty basic-auth credentials**. Set
  `HERMES_DASHBOARD_BASIC_AUTH_*` or bind the port to localhost before exposing
  the host.
- **Postgres publishes `5432` to the host** by default. Change `POSTGRES_PORT`
  or drop the port mapping on a shared machine.
- **RLS is the tenant boundary.** A caller that can set an arbitrary `Part-Id`
  reads that partition's data — treat `Part-Id` as authorization-relevant input
  in any front-end you put in front of this.

---

## ⚠️ Known limitations

- **`tasks/get` returns "Task not found" on PostgreSQL-only deployments.**
  Without AWS/DynamoDB the A2A SDK falls back to its in-memory `TaskStore`,
  which is *not* the same store as the `a2a_core` PostgreSQL persistence that
  `message/send` writes to. The task exists in `a2a_tasks`, but the SDK lookup
  misses it. `test_hermes_gateway_live.py` records this as SKIP rather than
  FAIL. Query the task via `a2a_core_graphql` or SQL in the meantime.
- **`GATEWAY_WORKERS > 1` breaks streaming and rate limiting** unless shared
  backends and sticky sessions are configured — task state, rate counters, and
  the SSE registry are per-process.
- **SSE is per-partition, not per-task.** All subscribers of `{ep}#{Part-Id}`
  see every task's events for that partition.
- **Compose `env_file` does not strip inline comments** — see the warning in
  [Editing `.env`](#️-editing-env-read-this-first). The test scripts' own loader
  *does*, so a bad line can pass a test and still break the container.
- **Module versions are unpinned** (`@main`); builds are not reproducible
  across time.

---

## 💡 Troubleshooting

| Symptom | Resolution |
|---|---|
| Build fails cloning the git modules | Check outbound network / proxy access to `github.com`. The repos are public — no credentials are involved. |
| `RUN --mount` / `--mount=type=secret` not supported | BuildKit is off. Set `DOCKER_BUILDKIT=1` (Docker Engine 23+ enables it by default). |
| Gateway unhealthy / restarts | `make gateway-logs`; check `HERMES_API_URL` / `HERMES_API_KEY` and the `PG_*` credentials. |
| `401 Unauthorized` | Get a fresh token via `POST /auth/token` (they expire after `ACCESS_TOKEN_EXP` minutes); check `JWT_SECRET_KEY` / Cognito settings. |
| Auth works in test scripts but not curl | The scripts fall back to a minted JWT from `JWT_SECRET_KEY`; your curl token may just be expired. |
| A2A tasks hang or error | Confirm Hermes is reachable from the gateway (`HERMES_API_URL`) and `API_SERVER_KEY` matches `HERMES_API_KEY` exactly — including no trailing inline comment. |
| Hermes auth fails for no visible reason | An inline `#` comment in `.env` was absorbed into the value. Put comments on their own line. |
| SSE connects but no chunks arrive | Send with `"stream": true`, connect the listener *before* sending, and check `A2A_STREAMING_ENABLED=true`. |
| `tasks/get` says "Task not found" | Expected on PostgreSQL-only deployments — see [Known limitations](#-known-limitations). |
| `make status` / `make shell`: "No such container" | You renamed the container in `.env`. Make doesn't read `.env` — run `A2A_GATEWAY_CONTAINER_NAME=<name> make shell`. |
| Bundled Hermes not starting | Ensure `COMPOSE_PROFILES` includes `hermes`, and that `www/hermes` + `www/projects` exist. |
| Bundled Postgres not starting | Ensure `COMPOSE_PROFILES` includes `postgres` and `PG_HOST=postgres`. |
| Gateway can't reach `postgres` / `hermes` by name | Those hostnames only resolve when the matching profile is active. Otherwise point `PG_HOST` / `HERMES_API_URL` at `host.docker.internal` or a real host. |
| Test script can't resolve host `hermes` | Expected — pass `--hermes-url http://127.0.0.1:8642`, or let the helper auto-swap in `127.0.0.1:$HERMES_GATEWAY_PORT`. |
| `relation "a2a_tasks" does not exist` | Set `initialize_tables=1` and restart the gateway. |
| Port already in use | Change `CONTAINER_PORT` (gateway), `HERMES_GATEWAY_PORT` / `HERMES_DASHBOARD_PORT` (hermes) or `POSTGRES_PORT` in `.env`. |
| Route changes not taking effect | `routes.yaml` is bind-mounted read-only; edit the host file and restart the gateway process (no rebuild). |

---

## 📝 License

MIT — see [LICENSE](LICENSE).
