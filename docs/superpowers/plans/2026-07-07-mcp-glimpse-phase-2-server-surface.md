# mcp-glimpse Phase 2 — MCP Server Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or
> superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. Read the roadmap
> (`2026-07-07-mcp-glimpse-roadmap.md`) Global Constraints first. This is the Phase-2 boundary
> re-plan (per kit backlog §11j), written against the tree as it exists after Phase 1.

**Goal:** Wire the Phase-1 pure core into a running FastMCP server exposing the full surface —
`introspect_mcp_context` + `submit_feedback` (both fully annotated), 4 prompts, 6 `glimpse://`
resources + the `ui://` App placeholder, and `/livez` `/readyz` `/version` routes — over **dual
transport** (stdio for `uvx`, stateful Streamable HTTP for the hosted endpoint), guarded by a
contract-snapshot test.

**Architecture:** `manifest.py` holds the authoritative name lists + `version()`. `connection.py`
observes server-side connection facts from the FastMCP `Context` (degrading over stdio).
`prompts.py` builds the 4 coaching prompts. `feedback.py` is the guarded durable store (local
JSONL now; Azure Table lands in Phase 6). `server.py::build_server()` wires everything with
`ToolAnnotations`, `_meta.ui`, transport security, and health routes. `cli.py::main()` runs stdio
by default, `--http` for the hosted mode. Faithful port of `~/repos/DevPartners/mcp-lens-python`
(`src/mcp_lens/{manifest,connection,prompts,feedback,server}.py`), renamed lens→glimpse, **plus two
additions the donor lacked: tool annotations, and the dual-transport CLI.**

**Tech Stack:** Python 3.13+, `mcp` SDK (FastMCP) 1.28.x, Pydantic v2, Starlette, pytest.

## Verified SDK contract (mcp 1.28.1 — probed live, guards against §11c drift)

- `FastMCP(name=, instructions=, transport_security=TransportSecuritySettings|None, stateless_http=False)`
  — **`stateless_http=False` is the default (stateful gate satisfied)**; set it explicitly anyway.
  Settings carry `host`/`port`/`streamable_http_path='/mcp'` (mutate via `mcp.settings.*`).
- `@mcp.tool(name=, description=, annotations=ToolAnnotations(...), meta=, structured_output=False)`.
  `ToolAnnotations` fields: `title, readOnlyHint, destructiveHint, idempotentHint, openWorldHint`
  (import `from mcp.types import ToolAnnotations`). A `ctx: Context` param is auto-hidden from the
  tool's input schema.
- `@mcp.prompt(name=, description=)`; `@mcp.resource(uri, name=, mime_type=, description=, meta=)`.
- `@mcp.custom_route(path, methods=[...])` → async Starlette handlers, mounted alongside `/mcp`.
- `TransportSecuritySettings(enable_dns_rebinding_protection, allowed_hosts, allowed_origins)` from
  `mcp.server.transport_security`.
- `await mcp.list_tools() -> list[mcp.types.Tool]` (**async**), each with `.name/.title/.description/
  .inputSchema/.annotations/.meta`. Same for `list_prompts()`, `list_resources()`. Use these for the
  contract-snapshot test.
- Run: `mcp.run(transport="stdio")` or `mcp.run(transport="streamable-http")`.
- `ctx.session.client_params` → `.protocolVersion`, `.clientInfo.name/.version`;
  `ctx.request_context.request` → Starlette request (headers/`mcp-session-id`), **absent over stdio**.

## Files (Phase 2)

- Create: `src/mcp_glimpse/manifest.py`, `connection.py`, `prompts.py`, `feedback.py`, `server.py`,
  `cli.py`
- Create: `resources/{snapshot-schema.json,explorations.md,primitives.md,what-servers-can-see.md,
  capabilities.md,protocol-versions.md}` (copied from donor, `lens://`→`glimpse://` renamed)
- Create: `tests/{test_manifest,test_feedback,test_connection,test_prompts,test_server,test_cli}.py`
- Modify: `pyproject.toml` (add `mcp>=1.28`, `[project.scripts]`, `[project.optional-dependencies].azure`)

## Interfaces PRODUCES (Phase 4/5/6 consume)

```text
manifest: TOOLS, PROMPTS, RESOURCES (list[str]); UI_RESOURCE_URI="ui://glimpse/index.html";
          RESOURCES_DIR, APP_DIST (Path); version() -> str
connection: observe(ctx: Any | None) -> ConnectionFacts   # transport auto-detected
prompts: suggest_explorations(), full_context_dump(), compare_vantage_points(),
         deep_tool_audit(focus: str | None) -> str
feedback: FeedbackStore (ABC, .record(kind,summary,detail,context)->dict), LocalFeedbackStore,
          AzureTableFeedbackStore, create_feedback_store() -> FeedbackStore
server: build_server(feedback: FeedbackStore | None = None) -> FastMCP
cli: main() -> None    # [project.scripts] mcp-glimpse = "mcp_glimpse.cli:main"
```

---

### Task 1: Project deps + manifest + resources

**Files:** modify `pyproject.toml`; create `src/mcp_glimpse/manifest.py`, `resources/*`,
`tests/test_manifest.py`.

**Interfaces produces:** `manifest.{TOOLS,PROMPTS,RESOURCES,UI_RESOURCE_URI,RESOURCES_DIR,APP_DIST,version()}`.

- [ ] **Step 1** — add to `pyproject.toml`: `dependencies += "mcp>=1.28"`; new
  `[project.optional-dependencies]` `azure = ["azure-data-tables>=12.5", "azure-identity>=1.17"]`;
  `[project.scripts]` `mcp-glimpse = "mcp_glimpse.cli:main"`. Run `uv sync`.
- [ ] **Step 2 (failing test)** — `tests/test_manifest.py`:

```python
from pathlib import Path
from mcp_glimpse import manifest


def test_tool_prompt_resource_name_lists():
    assert manifest.TOOLS == ["introspect_mcp_context", "submit_feedback"]
    assert manifest.PROMPTS == [
        "suggest_explorations", "full_context_dump",
        "compare_vantage_points", "deep_tool_audit",
    ]
    assert manifest.UI_RESOURCE_URI == "ui://glimpse/index.html"
    assert manifest.RESOURCES == [
        "glimpse://snapshot-schema", "glimpse://explorations", "glimpse://primitives",
        "glimpse://what-servers-can-see", "glimpse://capabilities",
        "glimpse://protocol-versions", manifest.UI_RESOURCE_URI,
    ]


def test_version_reads_version_file():
    assert manifest.version() == (Path(manifest.__file__).resolve().parents[2] / "VERSION").read_text().strip()


def test_resource_files_exist_and_are_renamed():
    for f in ("snapshot-schema.json", "explorations.md", "primitives.md",
              "what-servers-can-see.md", "capabilities.md", "protocol-versions.md"):
        text = (manifest.RESOURCES_DIR / f).read_text()
        assert "lens://" not in text
        assert "mcp-lens" not in text
```

- [ ] **Step 3** — copy the 6 resource files from the donor and rename in-place:

```bash
mkdir -p resources
cp ~/repos/DevPartners/mcp-lens-python/resources/*.{md,json} resources/
# rename scheme + branding (lens -> glimpse) inside the content
for f in resources/*.md resources/*.json; do
  sed -i '' -e 's#lens://#glimpse://#g' -e 's#ui://lens/#ui://glimpse/#g' \
            -e 's/mcp-lens/mcp-glimpse/g' -e 's/MCP Lens/MCP Glimpse/g' "$f"
done
```

- [ ] **Step 4** — create `src/mcp_glimpse/manifest.py` (port; `lens://`→`glimpse://`,
  `ui://lens/`→`ui://glimpse/`):

```python
"""This server's own advertised surface — the authoritative name lists and version.

Keep in sync with the actual registrations in server.py (they are the public contract;
the contract-snapshot test asserts they match).
"""
from __future__ import annotations

from pathlib import Path

UI_RESOURCE_URI = "ui://glimpse/index.html"

TOOLS: list[str] = ["introspect_mcp_context", "submit_feedback"]

PROMPTS: list[str] = [
    "suggest_explorations",
    "full_context_dump",
    "compare_vantage_points",
    "deep_tool_audit",
]

RESOURCES: list[str] = [
    "glimpse://snapshot-schema",
    "glimpse://explorations",
    "glimpse://primitives",
    "glimpse://what-servers-can-see",
    "glimpse://capabilities",
    "glimpse://protocol-versions",
    UI_RESOURCE_URI,
]

_REPO_ROOT = Path(__file__).resolve().parents[2]
RESOURCES_DIR = _REPO_ROOT / "resources"
APP_DIST = _REPO_ROOT / "app" / "dist" / "index.html"
_VERSION_FILE = _REPO_ROOT / "VERSION"


def version() -> str:
    try:
        if _VERSION_FILE.exists():
            return _VERSION_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        pass
    return "0.0.0"
```

- [ ] **Step 5** — `uv run pytest tests/test_manifest.py -v` → PASS. Commit
  `feat: manifest + glimpse:// resources`.

---

### Task 2: Feedback store (guarded; local JSONL now, Azure lazy)

Port `feedback.py` verbatim from the donor, renaming env vars `LENS_*`→`GLIMPSE_*`. The guard
(reject empty summary; cap 300/4000/2000 with `…[truncated]`; sanitize kind to
`feedback|feature-request|bug|praise`) lives in the `FeedbackStore` base so both backends inherit
it. Azure backend imports `azure.*` lazily (optional dep). `create_feedback_store()` reads
`GLIMPSE_TABLE_URI` / `AzureWebJobsStorage__tableServiceUri`; default `LocalFeedbackStore`.

**Files:** create `src/mcp_glimpse/feedback.py`, `tests/test_feedback.py`.

- [ ] **Step 1 (failing tests)** — `tests/test_feedback.py`:

```python
import json
from mcp_glimpse.feedback import LocalFeedbackStore, MAX_SUMMARY


def test_empty_summary_rejected_and_nothing_persisted():
    store = LocalFeedbackStore()
    result = store.record("bug", "   ")
    assert result["id"] == ""
    assert "required" in result["status"]
    assert store.records == []


def test_valid_feedback_recorded():
    store = LocalFeedbackStore()
    result = store.record("bug", "it broke", detail="stack", context="ctx")
    assert result["status"] == "recorded"
    assert result["id"]
    assert store.records[0]["kind"] == "bug"


def test_unknown_kind_is_sanitized():
    store = LocalFeedbackStore()
    store.record("PRAISE", "nice")
    assert store.records[0]["kind"] == "praise"
    store.record("banana", "x")
    assert store.records[1]["kind"] == "feedback"


def test_oversized_summary_truncated_with_marker():
    store = LocalFeedbackStore()
    store.record("feedback", "x" * (MAX_SUMMARY + 50))
    assert store.records[0]["summary"].endswith("…[truncated]")


def test_file_backend_persists(tmp_path):
    path = tmp_path / "fb.jsonl"
    LocalFeedbackStore(path).record("feedback", "hi")
    line = json.loads(path.read_text().splitlines()[0])
    assert line["summary"] == "hi"
```

- [ ] **Step 2** — create `feedback.py` = donor `feedback.py` with `LENS_TABLE_URI`→`GLIMPSE_TABLE_URI`,
  `LENS_MANAGED_IDENTITY_CLIENT_ID`→`GLIMPSE_MANAGED_IDENTITY_CLIENT_ID`, `LENS_FEEDBACK_FILE`→
  `GLIMPSE_FEEDBACK_FILE` (see donor source at
  `~/repos/DevPartners/mcp-lens-python/src/mcp_lens/feedback.py`; base guard + `LocalFeedbackStore`
  - `AzureTableFeedbackStore` + `create_feedback_store` unchanged otherwise).
- [ ] **Step 3** — `uv run pytest tests/test_feedback.py -v` → PASS. Commit `feat: guarded feedback store`.

---

### Task 3: Connection observer (transport auto-detected)

Port `connection.py`; **two changes**: `server_name="mcp-glimpse"`; and detect transport —
`streamable-http` when an HTTP request is present, else `stdio` (honest dual-transport; the donor
hardcoded `streamable-http`).

**Files:** create `src/mcp_glimpse/connection.py`, `tests/test_connection.py`.

- [ ] **Step 1 (failing tests)** — `tests/test_connection.py`:

```python
from types import SimpleNamespace
from mcp_glimpse import connection


def test_observe_none_gives_server_only_facts():
    facts = connection.observe(None)
    assert facts.server_name == "mcp-glimpse"
    assert facts.transport == "stdio"
    assert facts.protocol_version is None
    assert facts.client_name is None
    assert "introspect_mcp_context" in facts.server_tools
    assert facts.server_prompts and facts.server_resources


def test_observe_http_ctx_surfaces_client_and_session():
    ctx = SimpleNamespace(
        session=SimpleNamespace(
            client_params=SimpleNamespace(
                protocolVersion="2025-11-25",
                clientInfo=SimpleNamespace(name="test-host", version="1.2.3"),
            )
        ),
        request_context=SimpleNamespace(
            request=SimpleNamespace(headers={"mcp-session-id": "sess-abc"})
        ),
    )
    facts = connection.observe(ctx)
    assert facts.transport == "streamable-http"
    assert facts.protocol_version == "2025-11-25"
    assert facts.client_name == "test-host"
    assert facts.client_version == "1.2.3"
    assert facts.session_id == "sess-abc"
```

- [ ] **Step 2** — create `connection.py` (port; note the transport-detection change):

```python
"""Server-observed side of a report — what THIS server can see about the live connection.

Degrades honestly across transports: over Streamable HTTP the negotiated protocol/client and the
session id are surfaced; over stdio there is no HTTP request, so transport is "stdio" and headers
are absent. Always defensive — any probe that fails falls back to None ("not surfaced").
"""
from __future__ import annotations

import datetime
import os
from typing import Any

from . import manifest
from .model import ConnectionFacts

_STARTED_UTC = datetime.datetime.now(datetime.timezone.utc).isoformat()


def _try(getter) -> Any:
    try:
        return getter()
    except Exception:
        return None


def observe(ctx: Any | None = None) -> ConnectionFacts:
    protocol_version = client_name = client_version = session_id = None
    request = _try(lambda: ctx.request_context.request) if ctx is not None else None
    transport = "streamable-http" if request is not None else "stdio"

    if ctx is not None:
        params = _try(lambda: ctx.session.client_params)
        if params is not None:
            protocol_version = _try(lambda: params.protocolVersion)
            client_name = _try(lambda: params.clientInfo.name)
            client_version = _try(lambda: params.clientInfo.version)
        if request is not None:
            session_id = _try(lambda: request.headers.get("mcp-session-id"))

    return ConnectionFacts(
        protocol_version=protocol_version,
        client_name=client_name,
        client_version=client_version,
        transport=transport,
        session_id=session_id,
        server_name="mcp-glimpse",
        server_version=manifest.version(),
        server_edition="Python · FastMCP",
        server_instance=os.environ.get("CONTAINER_APP_REVISION"),
        server_started_utc=_STARTED_UTC,
        server_tools=list(manifest.TOOLS),
        server_prompts=list(manifest.PROMPTS),
        server_resources=list(manifest.RESOURCES),
    )
```

- [ ] **Step 3** — `uv run pytest tests/test_connection.py -v` → PASS. Commit `feat: connection observer with transport detection`.

---

### Task 4: Prompts

Port `prompts.py` verbatim (donor text is good) with `mcp-lens`→`mcp-glimpse`, `lens://`→`glimpse://`.

**Files:** create `src/mcp_glimpse/prompts.py`, `tests/test_prompts.py`.

- [ ] **Step 1 (failing tests)** — `tests/test_prompts.py`:

```python
from mcp_glimpse import prompts


def test_all_four_prompts_return_nonempty_text():
    assert "introspect_mcp_context" in prompts.suggest_explorations()
    assert "snapshot_json" in prompts.full_context_dump()
    assert "vantageGap" in prompts.compare_vantage_points()
    assert prompts.deep_tool_audit()


def test_deep_tool_audit_threads_focus():
    assert "network egress" in prompts.deep_tool_audit("network egress")


def test_prompts_have_no_lens_branding():
    for text in (prompts.suggest_explorations(), prompts.compare_vantage_points()):
        assert "mcp-lens" not in text
        assert "lens://" not in text
```

- [ ] **Step 2** — create `prompts.py` = donor `prompts.py` (at
  `~/repos/DevPartners/mcp-lens-python/src/mcp_lens/prompts.py`) with `mcp-lens`→`mcp-glimpse`,
  `lens://`→`glimpse://`. Keep `_read` sharing `explorations.md` with the resource so they can't drift.
- [ ] **Step 3** — `uv run pytest tests/test_prompts.py -v` → PASS. Commit `feat: 4 coaching prompts`.

---

### Task 5: Server wiring + contract-snapshot test

`build_server()` wires: 2 tools **with `ToolAnnotations`** + `_meta.ui`; 4 prompts; 6 `glimpse://`
resources + the `ui://` App resource (graceful placeholder until Phase 4 builds `app/dist`); transport
security from `MCP_ALLOWED_HOSTS`; `/livez` `/readyz` `/version` routes with the **`/readyz` schema
sentinel**. Annotations (from the ASP.NET donor's proven table):

| tool | title | readOnlyHint | idempotentHint | openWorldHint | destructiveHint |
|---|---|---|---|---|---|
| `introspect_mcp_context` | "Introspect MCP / agent context" | True | True | False | *(unset)* |
| `submit_feedback` | "Submit feedback / feature request / bug" | False | False | False | False |

**Files:** create `src/mcp_glimpse/server.py`, `tests/test_server.py`.

- [ ] **Step 1 (failing tests)** — `tests/test_server.py`:

```python
import asyncio
import json
from mcp_glimpse import manifest
from mcp_glimpse.feedback import LocalFeedbackStore
from mcp_glimpse.server import build_server


def _mcp():
    return build_server(feedback=LocalFeedbackStore())


def test_registered_tool_names_match_manifest():
    tools = asyncio.run(_mcp().list_tools())
    assert [t.name for t in tools] == manifest.TOOLS


def test_every_tool_is_annotated():
    tools = {t.name: t for t in asyncio.run(_mcp().list_tools())}
    intro = tools["introspect_mcp_context"].annotations
    assert intro.readOnlyHint is True
    assert intro.idempotentHint is True
    assert intro.openWorldHint is False
    assert intro.title == "Introspect MCP / agent context"
    fb = tools["submit_feedback"].annotations
    assert fb.readOnlyHint is False and fb.destructiveHint is False
    assert fb.title == "Submit feedback / feature request / bug"


def test_introspect_input_schema_hides_ctx_and_exposes_snapshot_json():
    tools = {t.name: t for t in asyncio.run(_mcp().list_tools())}
    props = tools["introspect_mcp_context"].inputSchema.get("properties", {})
    assert "snapshot_json" in props
    assert "ctx" not in props and "self" not in props


def test_introspect_meta_links_ui_resource():
    tools = {t.name: t for t in asyncio.run(_mcp().list_tools())}
    assert tools["introspect_mcp_context"].meta["ui"]["resourceUri"] == manifest.UI_RESOURCE_URI


def test_prompt_and_resource_counts_match_manifest():
    mcp = _mcp()
    assert [p.name for p in asyncio.run(mcp.list_prompts())] == manifest.PROMPTS
    uris = {str(r.uri) for r in asyncio.run(mcp.list_resources())}
    assert "glimpse://snapshot-schema" in uris


def test_introspect_call_returns_camelcase_wire_json():
    mcp = _mcp()
    result = asyncio.run(mcp.call_tool("introspect_mcp_context", {}))
    text = _extract_text(result)
    wire = json.loads(text)
    assert wire["source"] == "introspect_mcp_context"
    assert wire["connection"]["serverName"] == "mcp-glimpse"
    assert "totalTools" in wire["analysis"]


def test_submit_feedback_call_records():
    store = LocalFeedbackStore()
    mcp = build_server(feedback=store)
    asyncio.run(mcp.call_tool("submit_feedback", {"kind": "bug", "summary": "x"}))
    assert store.records and store.records[0]["kind"] == "bug"


def _extract_text(result):
    # FastMCP.call_tool returns (content_list, ...) or content_list depending on version;
    # normalize to the first text payload. Verify the exact shape during execution.
    content = result[0] if isinstance(result, tuple) else result
    block = content[0]
    return getattr(block, "text", block)
```

> **Execution note:** `FastMCP.call_tool`'s return shape (tuple vs list; structured vs
> `TextContent`) varies by SDK minor. Probe it at execution (`build_server(); await
> mcp.call_tool(...)`) and adjust `_extract_text`. The structural tests (`list_tools`/
> `list_prompts`/`list_resources`) are the primary contract gate and are stable.

- [ ] **Step 2** — create `server.py`: port the donor `server.py` with renames
  (`mcp-lens`→`mcp-glimpse`, `lens://`→`glimpse://`, `LensReport`→`GlimpseReport`, logger
  `mcp_lens`→`mcp_glimpse`, instructions text), **add `annotations=ToolAnnotations(...)`** per the
  table above (`from mcp.types import ToolAnnotations`), make the `ui://` resource return a graceful
  placeholder when `APP_DIST` is missing, and replace `/readyz` with the schema-sentinel version:

```python
    @mcp.custom_route("/readyz", methods=["GET"])
    async def readyz(_request: Request) -> JSONResponse:
        # Schema sentinel (kit §13a-3): no injected param may leak into a tool's input schema.
        leaked: list[str] = []
        for tool in await mcp.list_tools():
            props = (tool.inputSchema or {}).get("properties", {})
            leaked += [f"{tool.name}.{p}" for p in ("ctx", "self", "request") if p in props]
        app_built = manifest.APP_DIST.exists()
        ok = not leaked
        return JSONResponse(
            {"status": "ready" if ok else "degraded", "appBuilt": app_built, "schemaLeaks": leaked},
            status_code=200 if ok else 503,
        )
```

  (`/livez` → `PlainTextResponse("ok")`; `/version` → `{"name": "mcp-glimpse", "version":
  manifest.version()}`. The `ui://` resource body: `APP_DIST.read_text()` if it exists, else
  `"<!doctype html><meta charset=utf-8><title>mcp-glimpse</title><p>App build pending.</p>"`.)

- [ ] **Step 3** — `uv run pytest tests/test_server.py -v` → PASS. Commit
  `feat: FastMCP server — annotated tools, prompts, resources, health routes`.

---

### Task 6: Dual-transport CLI + live smoke

`cli.py::main()` — argparse: default **stdio** (`mcp.run(transport="stdio")`); `--http` runs
Streamable HTTP with `HOST`/`PORT` (env or `--port`). Console script `mcp-glimpse` (added in Task 1)
→ `uvx mcp-glimpse` runs stdio.

**Files:** create `src/mcp_glimpse/cli.py`, `tests/test_cli.py`.

- [ ] **Step 1 (failing test)** — `tests/test_cli.py`:

```python
from mcp_glimpse import cli


def test_parse_args_defaults_to_stdio():
    args = cli.parse_args([])
    assert args.http is False


def test_parse_args_http_with_port():
    args = cli.parse_args(["--http", "--port", "9000"])
    assert args.http is True
    assert args.port == 9000


def test_build_server_smoke():
    # main() blocks on a transport; verify the wiring cli.main relies on is constructible.
    from mcp_glimpse.server import build_server
    assert build_server() is not None
```

- [ ] **Step 2** — create `cli.py`:

```python
"""mcp-glimpse entry point — dual transport.

  uvx mcp-glimpse                 # stdio (default) — every local MCP host
  mcp-glimpse --http [--port N]   # stateful Streamable HTTP at /mcp (hosted mode)
"""
from __future__ import annotations

import argparse
import logging
import os

from .server import build_server


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="mcp-glimpse", description="Point your agent at itself.")
    parser.add_argument("--http", action="store_true", help="Run stateful Streamable HTTP instead of stdio.")
    parser.add_argument("--port", type=int, default=None, help="HTTP port (default $PORT or 8000).")
    return parser.parse_args(argv)


def main() -> None:
    args = parse_args()
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    mcp = build_server()
    if args.http:
        mcp.settings.host = os.environ.get("HOST", "0.0.0.0")
        mcp.settings.port = args.port or int(os.environ.get("PORT", "8000"))
        logging.getLogger("mcp_glimpse").info(
            "mcp-glimpse HTTP on http://%s:%s%s",
            mcp.settings.host, mcp.settings.port, mcp.settings.streamable_http_path,
        )
        mcp.run(transport="streamable-http")
    else:
        mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3** — `uv run pytest tests/test_cli.py -v` → PASS.
- [ ] **Step 4 (live smoke)** — start HTTP server, hit health routes + list tools over the wire:

```bash
MCP_ALLOWED_HOSTS='*' uv run mcp-glimpse --http --port 8123 &
sleep 2
curl -fsS localhost:8123/livez            # -> ok
curl -fsS localhost:8123/version          # -> {"name":"mcp-glimpse","version":"0.1.0"}
curl -fsS localhost:8123/readyz           # -> {"status":"ready",...} (200)
kill %1
```

- [ ] **Step 5** — full suite `uv run pytest -q` green; `bash scripts/check.sh` green. Commit
  `feat: dual-transport CLI (stdio + http)`.

---

## Phase 2 exit criteria

- `uvx`-style stdio entry (`mcp-glimpse`) and `--http` both run; `/livez` `/readyz` `/version` respond.
- `await list_tools()` shows both tools **fully annotated**; contract-snapshot test asserts names +
  annotations + `ctx` hidden from input schema + prompt/resource counts.
- `introspect_mcp_context` (with and without `snapshot_json`) returns camelCase wire JSON;
  `submit_feedback` records durably (local JSONL).
- Full pytest suite green (Phase 1 + Phase 2); `check.sh` green.
- **Deferred:** Azure Table backend + MI (Phase 6); the real `ui://` App build (Phase 4); the
  server→client primitives — elicitation/sampling/roots/logging/progress/completions (Phase 5).

**Next:** re-plan Phase 3 (signature analyses: context-cost + tool-poisoning) or Phase 4 (App view)
at its boundary.
