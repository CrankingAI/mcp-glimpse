"""Generate app/src/types.generated.ts from the Pydantic wire models (drift-gated).

Run: uv run python scripts/gen_app_types.py

The regenerate-and-diff test (tests/test_app_types.py) fails CI if the committed file drifts.
Never hand-edit types.generated.ts — edit the Pydantic models and regenerate. This is the kit's
"generated artifact + CI drift gate" pattern (backlog §13d): the Python side is authoritative, the
TS side consumes a committed artifact, and the two cannot silently disagree.
"""
from __future__ import annotations

import types as _pytypes
import typing
from pathlib import Path

from pydantic import BaseModel
from pydantic.alias_generators import to_camel

from mcp_glimpse import model as m

# Emit leaves first so every referenced interface is already declared.
_MODELS = [
    m.ModelInfo, m.HostInfo, m.ClientCapabilities, m.ServerRef, m.ToolRef,
    m.ContextWindow, m.EnvInfo, m.Persona, m.GlimpseSnapshot,
    m.ConnectionFacts, m.LargestServer, m.VantageGap, m.ServerCost,
    m.ContextCost, m.PoisoningFinding, m.AnnotationVisibility, m.Analysis, m.GlimpseReport,
]

_PRIMITIVES = {str: "string", int: "number", float: "number", bool: "boolean"}


def _ts_type(annotation: object) -> str:
    origin = typing.get_origin(annotation)
    args = typing.get_args(annotation)
    if origin in (typing.Union, _pytypes.UnionType):
        non_none = [a for a in args if a is not type(None)]
        return " | ".join(_ts_type(a) for a in non_none) or "null"
    if origin in (list, typing.List):  # noqa: UP006
        return f"{_ts_type(args[0])}[]"
    if annotation in _PRIMITIVES:
        return _PRIMITIVES[annotation]
    if isinstance(annotation, type) and issubclass(annotation, BaseModel):
        return annotation.__name__
    return "unknown"


def _is_optional(field) -> bool:
    annotation = field.annotation
    origin = typing.get_origin(annotation)
    if origin in (typing.Union, _pytypes.UnionType):
        return type(None) in typing.get_args(annotation)
    return not field.is_required()


def generate() -> str:
    lines = [
        "// GENERATED from src/mcp_glimpse/model.py by scripts/gen_app_types.py — do not edit.",
        "// Regenerate: uv run python scripts/gen_app_types.py (drift-gated by tests/test_app_types.py).",
        "",
    ]
    for cls in _MODELS:
        lines.append(f"export interface {cls.__name__} {{")
        for name, field in cls.model_fields.items():
            camel = to_camel(name)
            q = "?" if _is_optional(field) else ""
            lines.append(f"  {camel}{q}: {_ts_type(field.annotation)};")
        lines.append("}")
        lines.append("")
    return "\n".join(lines)


OUT = Path(__file__).resolve().parents[1] / "app" / "src" / "types.generated.ts"


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(generate(), encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
