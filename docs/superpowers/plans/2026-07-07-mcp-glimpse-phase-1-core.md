# mcp-glimpse Phase 1 — Pure Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended)
> or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax
> for tracking. This is Phase 1 of the build described in `2026-07-07-mcp-glimpse-roadmap.md`; read that
> roadmap's **Global Constraints** first — they bind every task here.

**Goal:** Build the pure-function core of mcp-glimpse — the camelCase wire models, the resilient
alias-tolerant snapshot parser, and the analyzer — fully unit-tested, with the wire-contract snapshot test
that guards the append-only contract. No FastMCP, no I/O, no network.

**Architecture:** Three modules with one responsibility each. `model.py` defines the Pydantic v2 wire
shapes and the load-bearing `to_wire_json()`. `parser.py` turns an untrusted agent-reported `snapshot_json`
string into a validated `GlimpseSnapshot` plus a list of human-readable warnings, tolerating aliases, case,
and malformed fragments. `analyzer.py` is a pure function from `(snapshot, connection facts) → Analysis`.
Everything is deterministic and testable without a running server. This is a faithful port of
`~/repos/DevPartners/mcp-lens-python` (`src/mcp_lens/{model,parser,analyzer}.py`), renamed lens→glimpse and
raised to Python 3.13.

**Tech Stack:** Python 3.13+, `uv`, Pydantic v2, pytest. No other runtime deps in this phase.

## Global Constraints (this phase's active subset — full list in the roadmap)

- **Wire is camelCase, pinned.** Serialize with `by_alias=True, exclude_none=True`. `exclude_none` is
  load-bearing: an undeclared hint must be **omitted (→ `undefined`)**, never `null`.
- **Names are the append-only contract.** The wire-contract snapshot test (Task 2) freezes camelCase keys;
  drift fails CI.
- **Never silently drop unrecognized input — warn.** Alias-tolerant, case-insensitive parsing; a stale-client
  advisory when deprecated field names arrive; a malformed single tool must not nuke the snapshot.
- **Package `mcp_glimpse`, server name `mcp-glimpse`.** (No `lens` naming survives.)
- **Python 3.13+**; `VERSION` file is the single source of truth for the version string.
- DRY, YAGNI, TDD, frequent commits.

## Interfaces this phase PRODUCES (later phases consume these exact names)

```text
mcp_glimpse.model:
  CamelModel(BaseModel)                          # alias_generator=to_camel, populate_by_name, extra=ignore
  ModelInfo, HostInfo, ClientCapabilities, ServerRef, ToolRef, ContextWindow,
  EnvInfo, Persona, GlimpseSnapshot, ConnectionFacts, LargestServer, VantageGap, Analysis
  ToolRef.has_annotations: bool  (property)      # any hint or title not None
  ToolRef.is_dangerous:   bool  (property)       # destructive_hint is True or open_world_hint is True
  GlimpseReport(source, snapshot, connection, analysis, warnings)
  GlimpseReport.to_wire_json() -> str            # model_dump_json(by_alias=True, exclude_none=True)

mcp_glimpse.analyzer:
  analyze(snapshot: GlimpseSnapshot | None, connection: ConnectionFacts) -> Analysis

mcp_glimpse.parser:
  SnapshotParseResult(snapshot: GlimpseSnapshot | None, warnings: list[str])   # frozen dataclass
  parse(snapshot_json: str | None) -> SnapshotParseResult
```

Phase 2 wires `parse → connection.observe → analyze → GlimpseReport(...).to_wire_json()` into the
`introspect_mcp_context` tool. Phase 3 adds fields to `Analysis`. Phase 4 generates TypeScript types from
these models.

---

### Task 1: Project skeleton & CI

Creates the runnable Python package so the TDD loop works. The meta-agent-md seed (Phase 0) ships platform
scaffolding but **no backend app code** — this package is added per-repo, so we create it here. If Phase 0
seeding already ran, this task's files land alongside the seeded tree (do not overwrite `AGENTS.md`,
`GOAL-STATE.md`, `scripts/`, `LICENSE`).

**Files:**

- Create: `pyproject.toml`
- Create: `VERSION`
- Create: `src/mcp_glimpse/__init__.py`
- Create: `tests/__init__.py`
- Create: `tests/test_version.py`
- Create: `.github/workflows/ci.yml`
- Create: `.gitignore` (if absent)

**Interfaces:**

- Consumes: nothing.
- Produces: an installable `mcp_glimpse` package; `uv run pytest` runs green; `mcp_glimpse.__version__`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_version.py`:

```python
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_pyproject_version_matches_version_file():
    version_file = (ROOT / "VERSION").read_text().strip()
    pyproject = tomllib.loads((ROOT / "pyproject.toml").read_text())
    assert pyproject["project"]["version"] == version_file


def test_package_exposes_version():
    import mcp_glimpse

    assert mcp_glimpse.__version__ == (ROOT / "VERSION").read_text().strip()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_version.py -v`
Expected: FAIL — collection error (`ModuleNotFoundError: No module named 'mcp_glimpse'`) / missing files.

- [ ] **Step 3: Create the package files**

`VERSION`:

```text
0.1.0
```

`pyproject.toml`:

```toml
[project]
name = "mcp-glimpse"
version = "0.1.0"
description = "Point your agent at itself — see every MCP server, tool, capability, and the wire."
requires-python = ">=3.13"
readme = "README.md"
license = { text = "MIT" }
authors = [{ name = "Bill Wilder", email = "codingoutloud@gmail.com" }]
dependencies = [
    "pydantic>=2.7",
]

[dependency-groups]
dev = [
    "pytest>=8.2",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/mcp_glimpse"]

[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = ["src"]
```

`src/mcp_glimpse/__init__.py`:

```python
"""mcp-glimpse — point your agent at itself."""
from pathlib import Path

__all__ = ["__version__"]

__version__ = (Path(__file__).resolve().parents[2] / "VERSION").read_text().strip()
```

`tests/__init__.py`: empty file.

`.github/workflows/ci.yml`:

```yaml
name: ci
on:
  push:
    branches: ["**"]
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v5
      - run: uv python install 3.13
      - run: uv sync --dev
      - run: uv run pytest -v
```

`.gitignore` (create if absent; append if present):

```text
.venv/
__pycache__/
*.pyc
.pytest_cache/
dist/
app/dist/
node_modules/
```

> **Note on the version guard:** `VERSION` is the canonical source. The literal `version` in
> `pyproject.toml` is kept in lockstep by `test_pyproject_version_matches_version_file` — a drift fails CI
> (the kit's "a version mismatch is a release bug", enforced by test). Phase 8 adds `bump-version.sh` to
> edit both atomically.

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/test_version.py -v`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
git add pyproject.toml VERSION src/mcp_glimpse/__init__.py tests/__init__.py tests/test_version.py .github/workflows/ci.yml .gitignore
git commit -m "chore: python package skeleton + CI + version guard"
```

---

### Task 2: Wire models & the pinned camelCase contract

The heart of the append-only contract. One file, `model.py`, defining every wire shape plus
`GlimpseReport.to_wire_json()`, guarded by the contract-snapshot test that asserts camelCase keys and that
undeclared hints are **omitted, not null**.

**Files:**

- Create: `src/mcp_glimpse/model.py`
- Create: `tests/test_model.py`

**Interfaces:**

- Consumes: nothing (pure Pydantic).
- Produces: all models in the "PRODUCES" block above; `GlimpseReport.to_wire_json() -> str`;
  `ToolRef.has_annotations` / `ToolRef.is_dangerous` properties.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_model.py`:

```python
import json

from mcp_glimpse.model import (
    Analysis,
    ConnectionFacts,
    GlimpseReport,
    GlimpseSnapshot,
    ToolRef,
    VantageGap,
)


def _report(analysis: Analysis | None = None, snapshot: GlimpseSnapshot | None = None) -> GlimpseReport:
    return GlimpseReport(
        source="test",
        snapshot=snapshot,
        connection=ConnectionFacts(),
        analysis=analysis or Analysis(),
    )


def _wire(report: GlimpseReport) -> dict:
    return json.loads(report.to_wire_json())


def test_wire_keys_are_camelcase():
    report = _report(
        analysis=Analysis(
            total_tools=3,
            total_servers=1,
            dangerous_tool_count=1,
            annotated_tool_count=2,
            unannotated_tool_count=1,
            duplicate_tool_names=["dup"],
            vantage_gap=VantageGap(server_sees=2, agent_sees=3),
        )
    )
    wire = _wire(report)
    a = wire["analysis"]
    assert a["totalTools"] == 3
    assert a["totalServers"] == 1
    assert a["dangerousToolCount"] == 1
    assert a["annotatedToolCount"] == 2
    assert a["unannotatedToolCount"] == 1
    assert a["duplicateToolNames"] == ["dup"]
    assert "total_tools" not in a
    assert a["vantageGap"]["serverSees"] == 2
    assert a["vantageGap"]["agentSees"] == 3
    c = wire["connection"]
    assert c["serverName"] == "mcp-glimpse"
    assert "serverVersion" in c
    assert c["serverTools"] == []


def test_declared_hints_are_camelcase_and_undeclared_hints_are_omitted():
    snap = GlimpseSnapshot(tools=[ToolRef(name="read_thing", read_only_hint=True)])
    tool = _wire(_report(snapshot=snap))["snapshot"]["tools"][0]
    assert tool["readOnlyHint"] is True
    assert "destructiveHint" not in tool
    assert "idempotentHint" not in tool
    assert "openWorldHint" not in tool


def test_camel_alias_and_snake_input_both_accepted():
    assert ToolRef.model_validate({"name": "t", "readOnlyHint": True}).read_only_hint is True
    assert ToolRef.model_validate({"name": "t", "read_only_hint": True}).read_only_hint is True


def test_tool_has_annotations_property():
    assert ToolRef(name="t", read_only_hint=True).has_annotations is True
    assert ToolRef(name="t", title="X").has_annotations is True
    assert ToolRef(name="t").has_annotations is False


def test_tool_is_dangerous_property():
    assert ToolRef(name="t", destructive_hint=True).is_dangerous is True
    assert ToolRef(name="t", open_world_hint=True).is_dangerous is True
    assert ToolRef(name="t", read_only_hint=True).is_dangerous is False
    assert ToolRef(name="t").is_dangerous is False


def test_snapshot_defaults_to_empty_collections():
    snap = GlimpseSnapshot()
    assert snap.servers == []
    assert snap.tools == []
    assert snap.skills == []
    assert snap.model is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_model.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mcp_glimpse.model'`.

- [ ] **Step 3: Write `model.py`**

Create `src/mcp_glimpse/model.py`:

```python
"""Pydantic v2 wire models for mcp-glimpse.

The wire contract is camelCase and pinned. Two rules are load-bearing (proven the hard
way in the mcp-lens builds):

1. Serialize with by_alias=True so field names go out camelCase. FastMCP's unstructured
   text conversion serializes by field name (snake_case) and IGNORES by_alias, so tools
   must return `to_wire_json()` (a JSON *string*) with structured_output=False, not a model.
2. Serialize with exclude_none=True so an undeclared annotation hint is OMITTED (the TS
   view then sees `undefined`), never `null`. The view keys "annotated?" off `!== undefined`.
"""
from __future__ import annotations

from pydantic import BaseModel, ConfigDict
from pydantic.alias_generators import to_camel


class CamelModel(BaseModel):
    model_config = ConfigDict(
        alias_generator=to_camel,
        populate_by_name=True,
        extra="ignore",
    )


class ModelInfo(CamelModel):
    id: str | None = None
    display_name: str | None = None
    provider: str | None = None


class HostInfo(CamelModel):
    name: str | None = None
    version: str | None = None


class ClientCapabilities(CamelModel):
    sampling: bool | None = None
    elicitation: bool | None = None
    roots: bool | None = None
    root_paths: list[str] | None = None


class ServerRef(CamelModel):
    name: str
    title: str | None = None
    offers_prompts: bool | None = None
    offers_resources: bool | None = None


class ToolRef(CamelModel):
    name: str
    server: str | None = None
    description: str | None = None
    read_only_hint: bool | None = None
    destructive_hint: bool | None = None
    idempotent_hint: bool | None = None
    open_world_hint: bool | None = None
    title: str | None = None

    @property
    def has_annotations(self) -> bool:
        return any(
            v is not None
            for v in (
                self.read_only_hint,
                self.destructive_hint,
                self.idempotent_hint,
                self.open_world_hint,
                self.title,
            )
        )

    @property
    def is_dangerous(self) -> bool:
        return self.destructive_hint is True or self.open_world_hint is True


class ContextWindow(CamelModel):
    used_tokens: int | None = None
    total_tokens: int | None = None


class EnvInfo(CamelModel):
    cwd: str | None = None
    date: str | None = None
    platform: str | None = None
    os_version: str | None = None


class Persona(CamelModel):
    name: str | None = None
    notes: str | None = None


class GlimpseSnapshot(CamelModel):
    model: ModelInfo | None = None
    host: HostInfo | None = None
    client_capabilities: ClientCapabilities | None = None
    servers: list[ServerRef] = []
    tools: list[ToolRef] = []
    context_window: ContextWindow | None = None
    environment: EnvInfo | None = None
    persona: Persona | None = None
    skills: list[str] = []
    notes: str | None = None


class ConnectionFacts(CamelModel):
    protocol_version: str | None = None
    client_name: str | None = None
    client_version: str | None = None
    transport: str | None = None
    session_id: str | None = None
    server_name: str = "mcp-glimpse"
    server_version: str = "0.0.0"
    server_edition: str | None = None
    server_instance: str | None = None
    server_started_utc: str | None = None
    server_tools: list[str] = []
    server_prompts: list[str] = []
    server_resources: list[str] = []


class LargestServer(CamelModel):
    name: str | None = None
    tool_count: int = 0


class VantageGap(CamelModel):
    server_sees: int = 0
    agent_sees: int = 0


class Analysis(CamelModel):
    total_tools: int = 0
    total_servers: int = 0
    largest_server: LargestServer | None = None
    servers_offering_prompts: int = 0
    servers_offering_resources: int = 0
    duplicate_tool_names: list[str] = []
    dangerous_tool_count: int = 0
    annotated_tool_count: int = 0
    unannotated_tool_count: int = 0
    inconsistencies: list[str] = []
    vantage_gap: VantageGap | None = None


class GlimpseReport(CamelModel):
    source: str
    snapshot: GlimpseSnapshot | None = None
    connection: ConnectionFacts
    analysis: Analysis
    warnings: list[str] = []

    def to_wire_json(self) -> str:
        return self.model_dump_json(by_alias=True, exclude_none=True)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_model.py -v`
Expected: PASS (6 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mcp_glimpse/model.py tests/test_model.py
git commit -m "feat: camelCase wire models + pinned to_wire_json contract"
```

---

### Task 3: Consistency-lens primitives (tokenizer + shadow-write detection)

The word-boundary tokenizer and the "declares read-only but reads like a write" heuristic, with the
false-positive guard that made the donor's lens trustworthy (`get_settings` must NOT match `set`). Kept as
standalone pure functions so a reviewer can gate the tokenizer independently of the counting logic in Task 4.

**Files:**

- Create: `src/mcp_glimpse/analyzer.py` (helpers only in this task; `analyze()` added in Task 4)
- Create: `tests/test_consistency.py`

**Interfaces:**

- Consumes: `mcp_glimpse.model.ToolRef`.
- Produces (module-internal, imported by tests and by Task 4's `analyze`):
  `_tokens(name: str) -> list[str]`, `_name_looks_like_write(tool: ToolRef) -> bool`,
  `_find_inconsistencies(tools: list[ToolRef]) -> list[str]`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_consistency.py`:

```python
from mcp_glimpse.analyzer import _find_inconsistencies, _name_looks_like_write, _tokens
from mcp_glimpse.model import ToolRef


def test_tokenizer_splits_snake_kebab_and_camel():
    assert _tokens("get_settings") == ["get", "settings"]
    assert _tokens("delete-file") == ["delete", "file"]
    assert _tokens("createUser") == ["create", "user"]
    assert _tokens("fs/write.file") == ["fs", "write", "file"]


def test_write_verb_detection_uses_whole_tokens_not_substrings():
    # "set" is a write verb; "get_settings" contains the substring "set" but not the token.
    assert _name_looks_like_write(ToolRef(name="set_value")) is True
    assert _name_looks_like_write(ToolRef(name="get_settings")) is False
    assert _name_looks_like_write(ToolRef(name="read_only")) is False
    assert _name_looks_like_write(ToolRef(name="deleteWidget")) is True


def test_contradictory_readonly_and_destructive_is_flagged():
    tools = [ToolRef(name="wipe", read_only_hint=True, destructive_hint=True)]
    out = _find_inconsistencies(tools)
    assert len(out) == 1
    assert "wipe" in out[0]


def test_readonly_but_write_name_is_flagged():
    out = _find_inconsistencies([ToolRef(name="delete_thing", read_only_hint=True)])
    assert len(out) == 1
    assert "delete_thing" in out[0]


def test_clean_tools_produce_no_inconsistencies():
    tools = [
        ToolRef(name="get_settings", read_only_hint=True),
        ToolRef(name="delete_thing", destructive_hint=True),
        ToolRef(name="list_items"),
    ]
    assert _find_inconsistencies(tools) == []
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_consistency.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mcp_glimpse.analyzer'`.

- [ ] **Step 3: Write the helpers in `analyzer.py`**

Create `src/mcp_glimpse/analyzer.py`:

```python
"""Pure analyzer for mcp-glimpse: snapshot + connection facts -> Analysis.

No I/O, no FastMCP, no network. The consistency lens uses a word-boundary tokenizer so
`get_settings` never matches the write verb `set` (a substring match would false-positive).
"""
from __future__ import annotations

import re

from mcp_glimpse.model import ToolRef

_CAMEL_BOUNDARY = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")
_SEPARATORS = re.compile(r"[ _\-./:]+")

_WRITE_VERBS = frozenset(
    {
        "delete", "remove", "write", "create", "update", "send", "post", "put",
        "drop", "set", "modify", "edit", "rename", "publish", "insert", "upload",
        "revoke", "disable", "enable", "move",
    }
)


def _tokens(name: str) -> list[str]:
    spaced = _CAMEL_BOUNDARY.sub(" ", name)
    parts = _SEPARATORS.split(spaced)
    return [p.lower() for p in parts if p]


def _name_looks_like_write(tool: ToolRef) -> bool:
    return any(token in _WRITE_VERBS for token in _tokens(tool.name))


def _find_inconsistencies(tools: list[ToolRef]) -> list[str]:
    out: list[str] = []
    for tool in tools:
        if tool.read_only_hint is True and tool.destructive_hint is True:
            out.append(
                f"{tool.name}: declares both readOnlyHint and destructiveHint (contradictory)"
            )
        elif tool.read_only_hint is True and _name_looks_like_write(tool):
            out.append(
                f"{tool.name}: declares readOnlyHint but its name reads like a write"
            )
    return out
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_consistency.py -v`
Expected: PASS (5 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mcp_glimpse/analyzer.py tests/test_consistency.py
git commit -m "feat: consistency lens — tokenizer + shadow-write detection"
```

---

### Task 4: The analyzer (`analyze`)

Composes the counts, largest-server, cross-server duplicate detection, dangerous/annotated tallies, and the
vantage gap into the `Analysis` model. Handles the null-snapshot (server-only view) case and the
`total_servers` fallback when `servers[]` is omitted.

**Files:**

- Modify: `src/mcp_glimpse/analyzer.py` (append `analyze` + its imports)
- Create: `tests/test_analyzer.py`

**Interfaces:**

- Consumes: `GlimpseSnapshot`, `ConnectionFacts`, `Analysis`, `LargestServer`, `VantageGap`, `ServerRef`,
  `ToolRef` from `model`; `_find_inconsistencies` from Task 3.
- Produces: `analyze(snapshot: GlimpseSnapshot | None, connection: ConnectionFacts) -> Analysis`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_analyzer.py`:

```python
from mcp_glimpse.analyzer import analyze
from mcp_glimpse.model import ConnectionFacts, GlimpseSnapshot, ServerRef, ToolRef


def conn(*server_tools: str) -> ConnectionFacts:
    return ConnectionFacts(server_tools=list(server_tools))


def test_counts_tools_and_servers():
    snap = GlimpseSnapshot(
        servers=[ServerRef(name="a"), ServerRef(name="b")],
        tools=[ToolRef(name="t1", server="a"), ToolRef(name="t2", server="a"), ToolRef(name="t3", server="b")],
    )
    result = analyze(snap, conn())
    assert result.total_tools == 3
    assert result.total_servers == 2


def test_largest_server():
    snap = GlimpseSnapshot(
        tools=[ToolRef(name="t1", server="a"), ToolRef(name="t2", server="a"), ToolRef(name="t3", server="b")],
    )
    result = analyze(snap, conn())
    assert result.largest_server is not None
    assert result.largest_server.name == "a"
    assert result.largest_server.tool_count == 2


def test_total_servers_falls_back_to_distinct_tool_servers_when_servers_omitted():
    snap = GlimpseSnapshot(
        tools=[ToolRef(name="t1", server="a"), ToolRef(name="t2", server="b")],
    )
    result = analyze(snap, conn())
    assert result.total_servers == 2


def test_cross_server_duplicate_tool_names():
    snap = GlimpseSnapshot(
        tools=[ToolRef(name="search", server="a"), ToolRef(name="search", server="b"), ToolRef(name="unique", server="a")],
    )
    result = analyze(snap, conn())
    assert result.duplicate_tool_names == ["search"]


def test_dangerous_counts_destructive_and_open_world():
    snap = GlimpseSnapshot(
        tools=[
            ToolRef(name="a", destructive_hint=True),
            ToolRef(name="b", open_world_hint=True),
            ToolRef(name="c", read_only_hint=True),
        ],
    )
    assert analyze(snap, conn()).dangerous_tool_count == 2


def test_annotated_and_unannotated_counts():
    snap = GlimpseSnapshot(
        tools=[
            ToolRef(name="a", read_only_hint=True),
            ToolRef(name="b", title="B"),
            ToolRef(name="c"),
        ],
    )
    result = analyze(snap, conn())
    assert result.annotated_tool_count == 2
    assert result.unannotated_tool_count == 1


def test_servers_offering_prompts_and_resources():
    snap = GlimpseSnapshot(
        servers=[
            ServerRef(name="a", offers_prompts=True, offers_resources=True),
            ServerRef(name="b", offers_prompts=True),
            ServerRef(name="c"),
        ],
    )
    result = analyze(snap, conn())
    assert result.servers_offering_prompts == 2
    assert result.servers_offering_resources == 1


def test_vantage_gap_compares_server_view_to_agent_view():
    snap = GlimpseSnapshot(tools=[ToolRef(name="t1"), ToolRef(name="t2"), ToolRef(name="t3")])
    result = analyze(snap, conn("own_tool_a", "own_tool_b"))
    assert result.vantage_gap is not None
    assert result.vantage_gap.server_sees == 2
    assert result.vantage_gap.agent_sees == 3


def test_null_snapshot_zeroes_agent_view_but_keeps_server_view():
    result = analyze(None, conn("own_tool_a", "own_tool_b"))
    assert result.total_tools == 0
    assert result.total_servers == 0
    assert result.dangerous_tool_count == 0
    assert result.largest_server is None
    assert result.vantage_gap is not None
    assert result.vantage_gap.server_sees == 2
    assert result.vantage_gap.agent_sees == 0


def test_inconsistencies_are_surfaced():
    snap = GlimpseSnapshot(tools=[ToolRef(name="delete_it", read_only_hint=True)])
    result = analyze(snap, conn())
    assert len(result.inconsistencies) == 1
    assert "delete_it" in result.inconsistencies[0]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_analyzer.py -v`
Expected: FAIL — `ImportError: cannot import name 'analyze'`.

- [ ] **Step 3: Append `analyze` to `analyzer.py`**

Add these imports at the top of `src/mcp_glimpse/analyzer.py` (alongside the existing `from mcp_glimpse.model import ToolRef`):

```python
from collections import Counter

from mcp_glimpse.model import (
    Analysis,
    ConnectionFacts,
    GlimpseSnapshot,
    LargestServer,
    VantageGap,
)
```

Append to the end of `src/mcp_glimpse/analyzer.py`:

```python
def analyze(snapshot: GlimpseSnapshot | None, connection: ConnectionFacts) -> Analysis:
    tools = snapshot.tools if snapshot else []
    servers = snapshot.servers if snapshot else []

    tools_by_server: Counter[str] = Counter()
    for tool in tools:
        if tool.server:
            tools_by_server[tool.server] += 1

    largest: LargestServer | None = None
    if tools_by_server:
        name, count = tools_by_server.most_common(1)[0]
        largest = LargestServer(name=name, tool_count=count)

    name_counts: Counter[str] = Counter(tool.name for tool in tools)
    duplicates = sorted(name for name, count in name_counts.items() if count > 1)

    if servers:
        total_servers = len(servers)
    else:
        total_servers = len({tool.server for tool in tools if tool.server})

    annotated = sum(1 for tool in tools if tool.has_annotations)

    return Analysis(
        total_tools=len(tools),
        total_servers=total_servers,
        largest_server=largest,
        servers_offering_prompts=sum(1 for s in servers if s.offers_prompts),
        servers_offering_resources=sum(1 for s in servers if s.offers_resources),
        duplicate_tool_names=duplicates,
        dangerous_tool_count=sum(1 for tool in tools if tool.is_dangerous),
        annotated_tool_count=annotated,
        unannotated_tool_count=len(tools) - annotated,
        inconsistencies=_find_inconsistencies(tools),
        vantage_gap=VantageGap(
            server_sees=len(connection.server_tools),
            agent_sees=len(tools),
        ),
    )
```

- [ ] **Step 4: Run the full suite to verify it passes**

Run: `uv run pytest -v`
Expected: PASS (all tasks 1–4 green).

- [ ] **Step 5: Commit**

```bash
git add src/mcp_glimpse/analyzer.py tests/test_analyzer.py
git commit -m "feat: analyzer — counts, duplicates, danger/annotation tallies, vantage gap"
```

---

### Task 5: The resilient snapshot parser

Turns an untrusted `snapshot_json` string into a validated `GlimpseSnapshot` plus warnings. Alias-tolerant
(canonical + short hint names), case-insensitive at every nesting level, warn-never-drop, stale-client
advisory, and resilient (a malformed single tool or scalar `servers`/`skills` degrades gracefully instead of
nuking the snapshot).

**Files:**

- Create: `src/mcp_glimpse/parser.py`
- Create: `tests/test_parser.py`

**Interfaces:**

- Consumes: all header/tool models from `model`.
- Produces: `SnapshotParseResult(snapshot, warnings)` (frozen dataclass) and
  `parse(snapshot_json: str | None) -> SnapshotParseResult`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_parser.py`:

```python
import pytest

from mcp_glimpse.parser import SnapshotParseResult, parse


@pytest.mark.parametrize("bad", [None, "", "   ", "not json", "[1, 2, 3]", "42", '"a string"'])
def test_unusable_input_yields_empty_without_warnings(bad):
    result = parse(bad)
    assert isinstance(result, SnapshotParseResult)
    assert result.snapshot is None
    assert result.warnings == []


def test_full_snapshot_parses():
    result = parse(
        """
        {
          "model": {"id": "claude-opus-4-8", "provider": "anthropic"},
          "servers": [{"name": "files", "offersPrompts": true}],
          "tools": [{"name": "read_file", "server": "files", "readOnlyHint": true}]
        }
        """
    )
    snap = result.snapshot
    assert snap is not None
    assert snap.model.id == "claude-opus-4-8"
    assert snap.servers[0].name == "files"
    assert snap.tools[0].read_only_hint is True
    assert result.warnings == []


def test_keys_are_case_insensitive_at_every_level():
    result = parse('{"Model": {"ID": "m1"}, "Tools": [{"Name": "t", "ReadOnlyHint": true}]}')
    assert result.snapshot.model.id == "m1"
    assert result.snapshot.tools[0].name == "t"
    assert result.snapshot.tools[0].read_only_hint is True


def test_short_alias_is_accepted_and_triggers_stale_client_advisory():
    result = parse('{"tools": [{"name": "t", "readOnly": true}]}')
    assert result.snapshot.tools[0].read_only_hint is True
    assert any("cached" in w.lower() for w in result.warnings)


def test_non_boolean_hint_is_ignored_with_warning():
    result = parse('{"tools": [{"name": "t", "readOnlyHint": "yes"}]}')
    assert result.snapshot.tools[0].read_only_hint is None
    assert any("boolean" in w.lower() for w in result.warnings)


def test_conflicting_alias_and_canonical_prefers_canonical_with_warning():
    result = parse('{"tools": [{"name": "t", "readOnlyHint": false, "readOnly": true}]}')
    assert result.snapshot.tools[0].read_only_hint is False
    assert any("conflict" in w.lower() for w in result.warnings)


def test_unrecognized_tool_field_is_kept_and_warned():
    result = parse('{"tools": [{"name": "t", "frobnicate": 1}]}')
    assert result.snapshot.tools[0].name == "t"
    assert any("frobnicate" in w for w in result.warnings)


def test_tool_with_no_name_is_skipped_with_warning():
    result = parse('{"tools": [{"description": "no name"}, {"name": "ok"}]}')
    names = [t.name for t in result.snapshot.tools]
    assert names == ["ok"]
    assert any("no name" in w.lower() for w in result.warnings)


def test_undeclared_server_is_warned():
    result = parse('{"servers": [{"name": "a"}], "tools": [{"name": "t", "server": "ghost"}]}')
    assert any("ghost" in w for w in result.warnings)


def test_malformed_tool_does_not_nuke_the_snapshot():
    result = parse('{"model": {"id": "m1"}, "tools": ["not an object", {"name": "ok"}]}')
    assert result.snapshot.model.id == "m1"
    assert [t.name for t in result.snapshot.tools] == ["ok"]


def test_scalar_servers_and_skills_degrade_without_crashing():
    result = parse('{"servers": "oops", "skills": 5, "tools": [{"name": "t"}]}')
    assert result.snapshot.servers == []
    assert result.snapshot.skills == []
    assert result.snapshot.tools[0].name == "t"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_parser.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mcp_glimpse.parser'`.

- [ ] **Step 3: Write `parser.py`**

Create `src/mcp_glimpse/parser.py`:

```python
"""Resilient, alias-tolerant parser for the agent-reported snapshot_json.

Rules (kit backend-mcp.md + backlog §13a): accept canonical AND deprecated short field
names; keys are case-insensitive at every nesting level; never silently drop unrecognized
input (warn instead); emit a stale-client advisory when deprecated names arrive; a
malformed single tool or a scalar where a list is expected must not nuke the snapshot.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

from pydantic import BaseModel

from mcp_glimpse.model import (
    ClientCapabilities,
    ContextWindow,
    EnvInfo,
    GlimpseSnapshot,
    HostInfo,
    ModelInfo,
    Persona,
    ServerRef,
    ToolRef,
)


@dataclass(frozen=True)
class SnapshotParseResult:
    snapshot: GlimpseSnapshot | None
    warnings: list[str] = field(default_factory=list)


_EMPTY = SnapshotParseResult(None, [])

_RECOGNIZED_TOOL_KEYS = {
    key.lower()
    for key in (
        "name", "server", "description", "title",
        "readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint",
        "readOnly", "destructive", "idempotent", "openWorld",
    )
}


def _ci_get(obj: dict[str, Any], name: str) -> Any:
    """Case-insensitive lookup mirroring .NET PropertyNameCaseInsensitive."""
    target = name.lower()
    for key, value in obj.items():
        if isinstance(key, str) and key.lower() == target:
            return value
    return None


def _ci_model_validate(cls: type[BaseModel], raw: Any) -> BaseModel | None:
    """Remap case-insensitive keys onto a model's field names/aliases, then validate."""
    if not isinstance(raw, dict):
        return None
    accepted: dict[str, str] = {}
    for field_name, info in cls.model_fields.items():
        accepted[field_name.lower()] = field_name
        if info.alias:
            accepted[info.alias.lower()] = info.alias
    remapped: dict[str, Any] = {}
    for key, value in raw.items():
        if not isinstance(key, str):
            continue
        target = accepted.get(key.lower())
        if target is not None:
            remapped[target] = value
    try:
        return cls.model_validate(remapped)
    except Exception:
        return None


def _read_tool(element: Any, warnings: list[str]) -> tuple[ToolRef | None, bool]:
    if not isinstance(element, dict):
        return None, False

    def read_str(key: str) -> str | None:
        value = _ci_get(element, key)
        return value if isinstance(value, str) else None

    name = read_str("name")
    if not name:
        warnings.append("a tool with no name was skipped")
        return None, False

    used_alias = False

    def read_hint(canonical: str, alias: str) -> bool | None:
        nonlocal used_alias
        canonical_value = _ci_get(element, canonical)
        alias_value = _ci_get(element, alias)
        if canonical_value is not None and alias_value is not None and canonical_value != alias_value:
            warnings.append(
                f"{name}: '{alias}' and '{canonical}' conflict; using '{canonical}'"
            )
            chosen: Any = canonical_value
        elif canonical_value is not None:
            chosen = canonical_value
        elif alias_value is not None:
            used_alias = True
            chosen = alias_value
        else:
            return None
        if not isinstance(chosen, bool):
            warnings.append(f"{name}: '{canonical}' is not a boolean; ignoring it")
            return None
        return chosen

    for key in element:
        if isinstance(key, str) and key.lower() not in _RECOGNIZED_TOOL_KEYS:
            warnings.append(f"{name}: unrecognized field '{key}' was ignored")

    tool = ToolRef(
        name=name,
        server=read_str("server"),
        description=read_str("description"),
        title=read_str("title"),
        read_only_hint=read_hint("readOnlyHint", "readOnly"),
        destructive_hint=read_hint("destructiveHint", "destructive"),
        idempotent_hint=read_hint("idempotentHint", "idempotent"),
        open_world_hint=read_hint("openWorldHint", "openWorld"),
    )
    return tool, used_alias


def _build_header(raw: dict[str, Any]) -> GlimpseSnapshot:
    def section(name: str, cls: type[BaseModel]) -> Any:
        value = _ci_get(raw, name)
        return _ci_model_validate(cls, value) if isinstance(value, dict) else None

    servers_raw = _ci_get(raw, "servers")
    servers = []
    if isinstance(servers_raw, list):
        for element in servers_raw:
            model = _ci_model_validate(ServerRef, element)
            if model is not None:
                servers.append(model)

    skills_raw = _ci_get(raw, "skills")
    skills = [s for s in skills_raw if isinstance(s, str)] if isinstance(skills_raw, list) else []

    notes = _ci_get(raw, "notes")
    return GlimpseSnapshot(
        model=section("model", ModelInfo),
        host=section("host", HostInfo),
        client_capabilities=section("clientCapabilities", ClientCapabilities),
        servers=servers,
        context_window=section("contextWindow", ContextWindow),
        environment=section("environment", EnvInfo),
        persona=section("persona", Persona),
        skills=skills,
        notes=notes if isinstance(notes, str) else None,
    )


def parse(snapshot_json: str | None) -> SnapshotParseResult:
    if not snapshot_json or not snapshot_json.strip():
        return _EMPTY
    try:
        raw = json.loads(snapshot_json)
    except (ValueError, TypeError):
        return _EMPTY
    if not isinstance(raw, dict):
        return _EMPTY

    warnings: list[str] = []
    snapshot = _build_header(raw)

    tools: list[ToolRef] = []
    alias_seen = False
    raw_tools = _ci_get(raw, "tools")
    if isinstance(raw_tools, list):
        for element in raw_tools:
            tool, used_alias = _read_tool(element, warnings)
            if tool is not None:
                tools.append(tool)
                alias_seen = alias_seen or used_alias
    snapshot.tools = tools

    declared = {server.name for server in snapshot.servers}
    if declared:
        for tool in tools:
            if tool.server and tool.server not in declared:
                warnings.append(f"{tool.name}: server '{tool.server}' is not in servers[]")

    if alias_seen:
        warnings.insert(
            0,
            "Some fields used pre-annotations names; your client may have a cached older "
            "schema — reconnect the connector to refresh it.",
        )

    return SnapshotParseResult(snapshot, warnings)
```

- [ ] **Step 4: Run the full suite to verify it passes**

Run: `uv run pytest -v`
Expected: PASS (all ~34 tests across the five tasks green).

- [ ] **Step 5: Commit**

```bash
git add src/mcp_glimpse/parser.py tests/test_parser.py
git commit -m "feat: resilient alias-tolerant snapshot parser with warn-never-drop"
```

---

## Phase 1 exit criteria (gate before Phase 2)

- `uv run pytest -v` green (~34 tests): version guard, wire contract (camelCase + exclude_none), consistency
  lens with the `get_settings ≠ set` false-positive guard, analyzer counts/vantage, resilient parser.
- The wire-contract test (`tests/test_model.py::test_wire_keys_are_camelcase` and
  `::test_declared_hints_are_camelcase_and_undeclared_hints_are_omitted`) is the append-only contract guard;
  Phase 2 extends it when it registers the tools.
- `GlimpseReport(...).to_wire_json()` produces the exact camelCase shape Phase 2's `introspect_mcp_context`
  returns and Phase 4's App consumes.
- No FastMCP, Azure, network, or filesystem writes were introduced (pure core).

**Next:** re-plan Phase 2 (MCP server surface) into its own detailed plan against the tree as it now exists,
per the roadmap. Phase 2 adds `manifest.py`, `connection.py`, `prompts.py`, `server.py`, `cli.py`, the
`resources/*.md` + `snapshot-schema.json` (renamed `glimpse://`), and the contract-snapshot CI test over the
registered tool names.
