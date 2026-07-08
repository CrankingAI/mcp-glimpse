"""Pure analyzer for mcp-glimpse: snapshot + connection facts -> Analysis.

No I/O, no FastMCP, no network. The consistency lens uses a word-boundary tokenizer so
`get_settings` never matches the write verb `set` (a substring match would false-positive).
"""
from __future__ import annotations

import re
from collections import Counter

from mcp_glimpse.model import (
    Analysis,
    ConnectionFacts,
    GlimpseSnapshot,
    LargestServer,
    ToolRef,
    VantageGap,
)
from mcp_glimpse.poisoning import scan as scan_poisoning
from mcp_glimpse.tokenizer import estimate as estimate_context_cost

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
        context_cost=estimate_context_cost(snapshot),
        tool_poisoning=scan_poisoning(tools),
    )
