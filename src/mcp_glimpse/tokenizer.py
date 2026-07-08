"""Context-cost accounting — estimate the token cost of the agent's own tool definitions.

Computable from the snapshot alone: names + descriptions (+ a small per-tool schema/annotation
overhead) approximate tokens. One computational base (tiktoken o200k_base) times a per-model-family
correction factor, displayed as a RANGE with a method footnote. Two honesty caveats live in the
method string: (a) hosts reformat tool definitions into their own prompt syntax before the model
sees them, so any estimate is approximate; (b) prompt caching cuts cost/latency but not window
occupancy. Never fabricates usedTokens.
"""
from __future__ import annotations

from collections import defaultdict
from functools import lru_cache

from .model import ContextCost, GlimpseSnapshot, ServerCost, ToolRef

# Per-tool overhead (JSON wrapper, schema scaffolding, annotation keys) beyond name+description.
_PER_TOOL_OVERHEAD = 12

# Family correction factors relative to tiktoken o200k_base (which IS the GPT/o200k tokenizer).
# Ranges are honest: prose/JSON token counts differ ~10-25% across tokenizer families.
_FAMILY_FACTORS: dict[str, tuple[float, float]] = {
    "openai": (0.98, 1.03),
    "anthropic": (1.05, 1.25),
    "google": (0.90, 1.15),
    "meta": (0.95, 1.20),
    "mistral": (0.95, 1.20),
}
_UNKNOWN_FACTOR = (0.85, 1.25)


def _family(model_id: str | None) -> str:
    m = (model_id or "").lower()
    if any(k in m for k in ("gpt", "o1-", "o3", "o4", "openai", "davinci")):
        return "openai"
    if any(k in m for k in ("claude", "anthropic")):
        return "anthropic"
    if any(k in m for k in ("gemini", "google", "palm")):
        return "google"
    if "llama" in m or "meta" in m:
        return "meta"
    if "mistral" in m or "mixtral" in m:
        return "mistral"
    return "unknown"


@lru_cache(maxsize=1)
def _encoder():
    import tiktoken

    return tiktoken.get_encoding("o200k_base")


def _count(text: str) -> int:
    try:
        return len(_encoder().encode(text))
    except Exception:
        # Offline / tiktoken vocab unavailable: ~4 chars per token heuristic.
        return max(1, len(text) // 4)


def _tool_text(tool: ToolRef) -> str:
    return " ".join(p for p in (tool.name, tool.description, tool.title) if p)


def estimate(snapshot: GlimpseSnapshot | None) -> ContextCost | None:
    if snapshot is None or not snapshot.tools:
        return None

    family = _family(snapshot.model.id if snapshot.model else None)
    f_low, f_high = _FAMILY_FACTORS.get(family, _UNKNOWN_FACTOR)

    per_server_base: dict[str, int] = defaultdict(int)
    base_total = 0
    for tool in snapshot.tools:
        tokens = _count(_tool_text(tool)) + _PER_TOOL_OVERHEAD
        base_total += tokens
        per_server_base[tool.server or "(unattributed)"] += tokens

    center = (f_low + f_high) / 2
    per_server = [
        ServerCost(name=name, estimated_tokens=int(round(tokens * center)))
        for name, tokens in sorted(per_server_base.items(), key=lambda kv: -kv[1])
    ]

    try:
        _encoder()
        tokenizer_note = "tiktoken o200k_base"
    except Exception:
        tokenizer_note = "~chars/4 heuristic (tiktoken unavailable)"

    window = snapshot.context_window.total_tokens if snapshot.context_window else None
    return ContextCost(
        estimated_tokens_low=int(round(base_total * f_low)),
        estimated_tokens_high=int(round(base_total * f_high)),
        window_total_tokens=window,
        per_server=per_server,
        model_family=family,
        method=(
            f"Estimated from tool name+description+title via {tokenizer_note} x {family} "
            "correction. Hosts reformat tool definitions before the model sees them, so any "
            "estimate is approximate; prompt caching cuts cost/latency but not window occupancy."
        ),
    )
