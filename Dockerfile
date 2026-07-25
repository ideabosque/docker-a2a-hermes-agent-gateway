# =============================================================================
# docker-a2a-hermes-agent-gateway — image
# =============================================================================
# A slim Python 3.12 image that runs the SilvaEngine Gateway with ONLY the
# a2a_daemon_engine module registered, exposing the native A2A protocol
# surface (JSON-RPC, GraphQL, SSE, agent-card) and bridging A2A tasks to a
# Hermes Agent API Server over HTTP + SSE.
#
# Both silvaengine_gateway and a2a_daemon_engine are pip-installed from git
# INTO the image over HTTPS (no host source mount, no SSH deploy key needed
# for public repos). Configuration is entirely env-driven at runtime via
# .env (see .env.example).
#
# For PRIVATE ideabosque repos, pass a GitHub Personal Access Token at build
# time via a BuildKit secret so git+https can clone them:
#   docker build --secret id=github_token,env=GITHUB_TOKEN .
# The RUN --mount below wires that token into git's credential helper for the
# install steps only; it is NOT persisted in the image.
# =============================================================================

# syntax=docker/dockerfile:1.6  # BuildKit (for --mount=secret)
FROM python:3.12-slim

WORKDIR /app

# ── System deps + uv ──────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    supervisor \
    curl \
    git \
    && curl -LsSf https://astral.sh/uv/install.sh | sh \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.local/bin:$PATH"

# ── Python dependencies ──────────────────────────────────────────────────────
# requirements.txt installs the third-party deps AND the shared SilvaEngine
# libraries (silvaengine_utility, silvaengine_dynamodb_base, ...) from git over
# HTTPS. requirements-modules.txt then installs silvaengine_gateway and
# a2a_daemon_engine --no-deps: their metadata declares engines / bare names
# not on PyPI (and intentionally absent from this A2A-only image); their real
# deps are already satisfied by requirements.txt.
#
# The --mount exposes an optional GITHUB_TOKEN BuildKit secret to git's
# credential helper so private repos clone over HTTPS. If no secret is passed,
# the mount is empty and only public repos resolve.
COPY requirements.txt requirements-modules.txt ./

# Configure git to use the token from the secret file as the password for
# github.com HTTPS clones. The helper reads $GITHUB_TOKEN (set by --mount).
# A standalone script is used (not an inline shell function) so quoting is
# robust across shells. If no secret is passed, $GITHUB_TOKEN is empty and
# only public repos resolve.
RUN --mount=type=secret,id=github_token,env=GITHUB_TOKEN \
    printf '#!/bin/sh\ntest "$1" = get && echo "username=x-access-token" && echo "password=$GITHUB_TOKEN"\n' \
        > /usr/local/bin/github-cred-helper && \
    chmod +x /usr/local/bin/github-cred-helper && \
    printf '[credential "https://github.com"]\n\thelper = /usr/local/bin/github-cred-helper\n' \
        > /root/.gitconfig-cred && \
    GIT_CONFIG_GLOBAL=/root/.gitconfig-cred \
    uv venv /opt/venv && \
    GIT_CONFIG_GLOBAL=/root/.gitconfig-cred \
    uv pip install --python /opt/venv/bin/python -r requirements.txt && \
    GIT_CONFIG_GLOBAL=/root/.gitconfig-cred \
    uv pip install --python /opt/venv/bin/python --no-deps -r requirements-modules.txt && \
    rm -f /root/.gitconfig-cred /usr/local/bin/github-cred-helper

ENV PATH="/opt/venv/bin:$PATH"

# ── PostgreSQL is the sole persistence backend ──────────────────────────────
# a2a_daemon_engine's Config defaults DB_BACKEND to "dynamodb"; we force
# "postgresql" here so the gateway always wires the SQLAlchemy session even if
# .env omits db_backend. Override only if you know why.
ENV db_backend=postgresql

# ── A2A-only route manifest ─────────────────────────────────────────────────
# The packaged gateway ships a routes.yaml registering every engine module
# (KGE, RFQ, MCP, ...). This image exposes ONLY a2a_daemon_engine, so we bake
# a self-contained manifest (no !include children) and point
# GATEWAY_ROUTES_CONFIG_PATH at it. Override at runtime by mounting your own.
COPY routes.yaml /app/routes.yaml

# ── Supervisor ───────────────────────────────────────────────────────────────
RUN mkdir -p /var/log/supervisor
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# ── Non-root user ────────────────────────────────────────────────────────────
RUN useradd -m -u 1000 gateway && \
    mkdir -p /app/data && \
    chown -R gateway:gateway /app

EXPOSE 8000

# Default route manifest is the A2A-only one baked above. Override via .env.
ENV GATEWAY_ROUTES_CONFIG_PATH=/app/routes.yaml

# Start supervisor as root (it drops privileges for the gateway process).
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]