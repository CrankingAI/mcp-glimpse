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
