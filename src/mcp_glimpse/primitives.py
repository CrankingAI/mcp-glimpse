"""Server->client primitive demonstrators + capability guards.

Everything here is best-effort and degrades gracefully: an MCP host that doesn't support a
capability (or a call that errors) must never break introspection. The point is to DEMONSTRATE
each primitive live where available and report honestly where not.
"""
from __future__ import annotations

import asyncio
import inspect
from typing import Any

# Timeouts so a client that advertises a capability but never answers can't hang a tool.
ROOTS_TIMEOUT = 15
SAMPLING_TIMEOUT = 60
ELICIT_TIMEOUT = 300  # user-interactive; generous, but never infinite


def _try(getter):
    try:
        return getter()
    except Exception:
        return None


def client_supports(ctx: Any, capability: str) -> bool:
    """True when the negotiated client advertised `capability` (sampling/elicitation/roots)."""
    caps = _try(lambda: ctx.session.client_params.capabilities)
    return bool(caps is not None and getattr(caps, capability, None) is not None)


async def best_effort(fn, *args, **kwargs):
    """Call fn (sync or async) and swallow any error — for demonstrator side-effects
    (logging, progress) that must never break the tool."""
    try:
        result = fn(*args, **kwargs)
        if inspect.isawaitable(result):
            return await result
        return result
    except Exception:
        return None


class _Confirm:
    """Lazily-built one-field boolean elicitation schema (a Pydantic model type)."""

    _model = None

    @classmethod
    def model(cls):
        if cls._model is None:
            from pydantic import BaseModel, Field

            class ConfirmSchema(BaseModel):
                confirm: bool = Field(default=False, description="Confirm this action now?")

            cls._model = ConfirmSchema
        return cls._model


async def confirm(ctx: Any, message: str) -> str:
    """Elicit a boolean confirmation with a timeout. Returns one of: 'unsupported' (client can't
    elicit), 'confirmed', 'declined', or 'failed' (error/timeout). Callers decide how to degrade."""
    if not client_supports(ctx, "elicitation"):
        return "unsupported"
    try:
        result = await asyncio.wait_for(ctx.elicit(message, _Confirm.model()), timeout=ELICIT_TIMEOUT)
        action = getattr(result, "action", None)
        data = getattr(result, "data", None)
        if action == "accept" and data is not None and getattr(data, "confirm", False):
            return "confirmed"
        return "declined"
    except Exception:
        return "failed"


async def fetch_roots(ctx: Any) -> list[str]:
    """Call roots/list when the client advertises roots; return the workspace root URIs."""
    if not client_supports(ctx, "roots"):
        return []
    try:
        result = await asyncio.wait_for(ctx.session.list_roots(), timeout=ROOTS_TIMEOUT)
        return [str(root.uri) for root in result.roots]
    except Exception:
        return []


async def narrate(ctx: Any, summary_line: str) -> str | None:
    """Sampling demonstrator: ask the client's model for a one-paragraph narrative of the
    environment. Degrades to None when sampling is unsupported or the call fails."""
    if not client_supports(ctx, "sampling"):
        return None
    try:
        from mcp.types import SamplingMessage, TextContent

        prompt = (
            "In one plain-language paragraph for a technical but non-expert reader, describe this "
            "agent's MCP environment. No markdown, no lists. Facts: " + summary_line
        )
        result = await asyncio.wait_for(
            ctx.session.create_message(
                messages=[SamplingMessage(role="user", content=TextContent(type="text", text=prompt))],
                max_tokens=220,
            ),
            timeout=SAMPLING_TIMEOUT,
        )
        text = getattr(result.content, "text", None)
        return text.strip() if isinstance(text, str) and text.strip() else None
    except Exception:
        return None
