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
