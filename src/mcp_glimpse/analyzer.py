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
