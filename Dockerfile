# syntax=docker/dockerfile:1
# Build for Azure Container Apps (amd64):
#   docker build --platform linux/amd64 -t mcp-glimpse .
# (Apple-Silicon arm64 images exit 1 on ACA with "ActivationFailed, 0 replicas".)

# --- Stage 1: build the ui:// App view into one self-contained HTML file ------------------
FROM node:22-slim AS view
WORKDIR /view
COPY app/package.json app/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY app/ ./
RUN npm run build            # -> /view/dist/index.html (vite-plugin-singlefile)

# --- Stage 2: Python runtime --------------------------------------------------------------
FROM python:3.13-slim AS runtime
COPY --from=ghcr.io/astral-sh/uv:0.11 /uv /uvx /bin/
WORKDIR /srv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy

# Dependencies first (layer cache). The 'azure' extra powers the Table feedback/card stores.
COPY pyproject.toml uv.lock README.md ./
COPY src ./src
RUN uv sync --frozen --no-dev --extra azure

# Runtime assets at the repo-root-relative paths the manifest expects.
COPY resources ./resources
COPY VERSION ./VERSION
COPY --from=view /view/dist/ ./app/dist/

# Pre-cache the tiktoken o200k_base vocab so context-cost never needs network at runtime.
ENV TIKTOKEN_CACHE_DIR=/srv/.tiktoken
# Put the synced venv first on PATH so the runtime never invokes `uv run` (which re-syncs —
# rebuilds the project + recompiles ~1.5k files of bytecode — on every cold start).
ENV PATH="/srv/.venv/bin:$PATH"
RUN mkdir -p /srv/.tiktoken && python -c "import tiktoken; tiktoken.get_encoding('o200k_base')"

ENV HOST=0.0.0.0 PORT=8080 LOG_LEVEL=INFO
EXPOSE 8080
CMD ["mcp-glimpse", "--http"]
