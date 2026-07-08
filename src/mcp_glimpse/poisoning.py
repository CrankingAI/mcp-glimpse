"""Tool-poisoning lens — heuristic scan of snapshot tool descriptions.

Clearly labeled heuristics (not detections): injection-style directives, exfiltration urges,
invisible/bidirectional Unicode, cross-server tool-shadowing, and suspiciously long descriptions.
Findings render like the consistency lens — a prompt to look closer, never a verdict.
"""
from __future__ import annotations

import re
from collections import defaultdict

from .model import PoisoningFinding, ToolRef

# Injection-style directives that try to override the agent's own instructions.
_INJECTION = re.compile(
    r"ignore (all |the )?(previous|prior|above)"
    r"|disregard (all |the )?(previous|prior|above)"
    r"|you must always|always call this tool (first|before)"
    r"|before (using|calling) any other"
    r"|do ?n.?t tell the user|without telling the user|do not mention|system prompt",
    re.IGNORECASE,
)

# Exfiltration urges — moving secrets/data off-box.
_EXFIL = re.compile(
    r"(send|post|upload|exfiltrate|forward|email|leak|transmit)[^.]{0,60}"
    r"(secret|api[ _-]?key|credential|token|password|env(ironment)?|\.ssh|private key|cookie)"
    r"|(curl|fetch|https?://)[^.]{0,60}(secret|key|token|credential|password)",
    re.IGNORECASE,
)

# Invisible / bidirectional Unicode used to hide instructions in plain sight: zero-width
# (200b-200f), bidi overrides + isolates (202a-202e, 2066-2069), word-joiners (2060-2064),
# BOM (feff), and Unicode tag chars (e0000-e007f). Built from code points so no invisible
# characters live in this source file. U+200D (ZERO WIDTH JOINER) is EXCLUDED because ordinary
# emoji ZWJ sequences (technologist, family, flags) use it — flagging those is a false positive.
_HIDDEN_RANGES = [
    (0x200B, 0x200C), (0x200E, 0x200F), (0x202A, 0x202E), (0x2060, 0x2064),
    (0x2066, 0x2069), (0xFEFF, 0xFEFF), (0xE0000, 0xE007F),
]
_HIDDEN = re.compile("[" + "".join(f"{chr(lo)}-{chr(hi)}" for lo, hi in _HIDDEN_RANGES) + "]")

_LONG_DESCRIPTION = 1200


def scan(tools: list[ToolRef]) -> list[PoisoningFinding]:
    findings: list[PoisoningFinding] = []

    servers_by_name: dict[str, set[str]] = defaultdict(set)
    for tool in tools:
        servers_by_name[tool.name].add(tool.server or "")

    for tool in tools:
        desc = tool.description or ""
        if _INJECTION.search(desc):
            findings.append(PoisoningFinding(
                tool=tool.name, category="injection",
                detail="description contains instruction-override phrasing",
            ))
        if _EXFIL.search(desc):
            findings.append(PoisoningFinding(
                tool=tool.name, category="exfiltration",
                detail="description pairs a send/upload verb with a secret/credential term",
            ))
        if _HIDDEN.search(f"{tool.name} {desc}"):
            findings.append(PoisoningFinding(
                tool=tool.name, category="hidden-unicode",
                detail="name or description contains invisible/bidirectional Unicode",
            ))
        if len(desc) > _LONG_DESCRIPTION:
            findings.append(PoisoningFinding(
                tool=tool.name, category="excessive-length",
                detail=f"description is {len(desc)} chars (unusually long — can bury directives)",
            ))

    for name, servers in servers_by_name.items():
        real = sorted(s for s in servers if s)
        if len(real) > 1:
            findings.append(PoisoningFinding(
                tool=name, category="shadowing",
                detail=f"tool name appears on multiple servers: {', '.join(real)}",
            ))

    return findings
