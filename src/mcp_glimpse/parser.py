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

# Bound on the public, anonymous snapshot input (analysis scales linearly, but keep it sane).
MAX_SNAPSHOT_BYTES = 1_000_000

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
    if len(snapshot_json) > MAX_SNAPSHOT_BYTES:
        return SnapshotParseResult(
            None,
            [f"snapshot_json is {len(snapshot_json)} bytes, over the "
             f"{MAX_SNAPSHOT_BYTES}-byte limit; not parsed"],
        )
    try:
        raw = json.loads(snapshot_json)
    except (ValueError, TypeError):
        return _EMPTY
    if not isinstance(raw, dict):
        return _EMPTY

    warnings: list[str] = []
    # Warn (don't silently drop) when a collection field arrives as a scalar/object.
    for collection in ("servers", "tools", "skills"):
        value = _ci_get(raw, collection)
        if value is not None and not isinstance(value, list):
            warnings.append(f"'{collection}' should be a list; it was ignored")
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
