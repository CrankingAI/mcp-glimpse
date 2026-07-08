"""FastMCP wiring for mcp-glimpse: 2 tools, 4 prompts, 6 glimpse:// resources + the ui:// view.

Wire-format contract (do not break):
* Tools return the GlimpseReport serialized as **camelCase** JSON text via
  ``GlimpseReport.to_wire_json`` — never a pydantic model, because FastMCP's unstructured-text
  conversion serializes models by field name (snake_case), which the view cannot read.
* ``introspect_mcp_context`` carries ``_meta`` ``ui.resourceUri`` so hosts render its result in
  the app rectangle; the ``ui://`` resource carries ``_meta`` ``ui.prefersBorder`` and the
  ``text/html;profile=mcp-app`` mimetype.
* Every tool declares full annotations — mcp-glimpse must be the best-annotated server its users have.
"""

from __future__ import annotations

import logging
import os

from mcp.server.fastmcp import Context, FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse

from . import connection, manifest, prompts
from .analyzer import analyze
from .feedback import FeedbackStore, create_feedback_store
from .model import GlimpseReport
from .parser import parse

logger = logging.getLogger("mcp_glimpse")

_TOOL_UI_META = {"ui": {"resourceUri": manifest.UI_RESOURCE_URI}}
_RESOURCE_UI_META = {"ui": {"prefersBorder": True}}

_APP_PLACEHOLDER = (
    "<!doctype html><meta charset=utf-8><title>mcp-glimpse</title>"
    "<p>App build pending — run the view build (Phase 4).</p>"
)

_INTROSPECT_DESCRIPTION = (
    "Introspect and visualize your MCP / agent context in the app rectangle. snapshot_json "
    "is OPTIONAL — omit it for the server-only view (what THIS server observes about the live "
    "connection: its own tools, the negotiated protocol/session, its edition), or provide it "
    "for the full panoramic view across ALL your connected servers. When provided, pass "
    "a JSON object with any of these fields (omit what you cannot determine) — "
    "model {id}, host {name,version}, "
    "clientCapabilities {sampling,elicitation,roots,rootPaths}, "
    "servers [{name,title,offersPrompts,offersResources}], "
    "tools [{name,server,description, and the tool's DECLARED MCP annotations: "
    "readOnlyHint,destructiveHint,idempotentHint,openWorldHint,title}], "
    "contextWindow {usedTokens,totalTokens}, environment {cwd,date,platform,osVersion}, "
    "persona {name,notes}, skills [string], notes. For each tool, report the annotation "
    "hints exactly as declared in its definition; leave a hint out when the tool declares "
    "none (an unannotated tool is itself worth showing). The short forms "
    "readOnly/destructive/idempotent/openWorld are ALSO accepted; any tool field that is "
    "not recognized is echoed back as a warning rather than silently dropped. The full "
    "machine-readable JSON Schema is the glimpse://snapshot-schema resource. Enumerate EVERY "
    "tool across ALL your connected servers. Use the full_context_dump prompt first."
)

_SUBMIT_FEEDBACK_DESCRIPTION = (
    "Submit product feedback, a feature suggestion, or a bug report. Use this when a task "
    "runs into something these tools cannot do."
)


def _transport_security() -> TransportSecuritySettings | None:
    """DNS-rebinding protection defaults to a localhost-only allowlist (great for local dev).
    Behind a public host (Azure Container Apps) the request Host is the deployed FQDN, which the
    default allowlist rejects with 421 "Invalid Host header". Configure via env:

    * ``MCP_ALLOWED_HOSTS='*'``  -> disable the check (public server; the edge is the boundary).
    * ``MCP_ALLOWED_HOSTS='a,b'`` -> allow exactly those hosts (protection stays on).
    * unset -> SDK default (localhost), which keeps local runs secure.
    """
    hosts = os.environ.get("MCP_ALLOWED_HOSTS")
    if not hosts:
        return None
    if hosts.strip() == "*":
        return TransportSecuritySettings(enable_dns_rebinding_protection=False)
    origins = os.environ.get("MCP_ALLOWED_ORIGINS", hosts)
    return TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=[h.strip() for h in hosts.split(",") if h.strip()],
        allowed_origins=[o.strip() for o in origins.split(",") if o.strip()],
    )


def build_server(feedback: FeedbackStore | None = None) -> FastMCP:
    store = feedback if feedback is not None else create_feedback_store()

    kwargs: dict = {
        "name": "mcp-glimpse",
        "instructions": (
            "A glimpse of your own MCP / agent context. Call introspect_mcp_context — with a "
            "snapshot of everything you can see for the full panoramic view, or with no argument "
            "for the narrow server-only view."
        ),
        "stateless_http": False,  # STATEFUL — the gate for elicitation/sampling/roots (do not flip).
    }
    security = _transport_security()
    if security is not None:
        kwargs["transport_security"] = security
    mcp = FastMCP(**kwargs)

    # --- Tools ---------------------------------------------------------------------------

    @mcp.tool(
        name="introspect_mcp_context",
        description=_INTROSPECT_DESCRIPTION,
        annotations=ToolAnnotations(
            title="Introspect MCP / agent context",
            readOnlyHint=True,
            idempotentHint=True,
            openWorldHint=False,
        ),
        meta=_TOOL_UI_META,
        structured_output=False,
    )
    def introspect_mcp_context(ctx: Context, snapshot_json: str | None = None) -> str:
        parsed = parse(snapshot_json)
        conn = connection.observe(ctx)
        analysis = analyze(parsed.snapshot, conn)
        logger.info(
            "introspect_mcp_context: agentTools=%s serverTools=%s servers=%s warnings=%s",
            analysis.total_tools,
            analysis.vantage_gap.server_sees,
            analysis.total_servers,
            len(parsed.warnings),
        )
        report = GlimpseReport(
            source="introspect_mcp_context",
            warnings=parsed.warnings,
            snapshot=parsed.snapshot,
            connection=conn,
            analysis=analysis,
        )
        return report.to_wire_json()

    @mcp.tool(
        name="submit_feedback",
        description=_SUBMIT_FEEDBACK_DESCRIPTION,
        annotations=ToolAnnotations(
            title="Submit feedback / feature request / bug",
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=False,
            openWorldHint=False,
        ),
        structured_output=False,
    )
    def submit_feedback(
        kind: str,
        summary: str,
        detail: str | None = None,
        context: str | None = None,
    ) -> dict[str, str]:
        logger.info("submit_feedback: kind=%s", kind)
        return store.record(kind, summary, detail, context)

    # --- Prompts -------------------------------------------------------------------------

    @mcp.prompt(
        name="suggest_explorations",
        description=(
            "A menu of high-signal questions to ask mcp-glimpse — pick one and it renders in the "
            "app rectangle."
        ),
    )
    def suggest_explorations() -> str:
        return prompts.suggest_explorations()

    @mcp.prompt(
        name="full_context_dump",
        description="A checklist for enumerating everything you can see, then calling introspect_mcp_context.",
    )
    def full_context_dump() -> str:
        return prompts.full_context_dump()

    @mcp.prompt(
        name="compare_vantage_points",
        description="Call introspect_mcp_context with and without a snapshot; narrate how much more the agent sees than the server.",
    )
    def compare_vantage_points() -> str:
        return prompts.compare_vantage_points()

    @mcp.prompt(
        name="deep_tool_audit",
        description="Classify every available tool by capability/risk, then render it.",
    )
    def deep_tool_audit(focus: str | None = None) -> str:
        return prompts.deep_tool_audit(focus)

    # --- Resources -----------------------------------------------------------------------

    def _read_resource(file: str) -> str:
        return (manifest.RESOURCES_DIR / file).read_text(encoding="utf-8")

    @mcp.resource(
        "glimpse://snapshot-schema",
        name="introspect_mcp_context snapshot schema",
        mime_type="application/schema+json",
        description=(
            "The JSON Schema (draft 2020-12) for the introspect_mcp_context snapshot_json argument — "
            "the machine-readable contract, including the deprecated short-name aliases. Read "
            "this to shape a valid snapshot."
        ),
    )
    def snapshot_schema() -> str:
        return _read_resource("snapshot-schema.json")

    @mcp.resource(
        "glimpse://explorations",
        name="Interesting explorations",
        mime_type="text/markdown",
        description=(
            "A menu of high-signal questions mcp-glimpse is built to answer — each a ready-to-run "
            "exploration that ends in an introspect_mcp_context call. The reference twin of the "
            "suggest_explorations prompt."
        ),
    )
    def explorations() -> str:
        return _read_resource("explorations.md")

    @mcp.resource(
        "glimpse://primitives",
        name="MCP primitives",
        mime_type="text/markdown",
        description=(
            "Field glossary of every MCP primitive: tools, prompts, resources, sampling, "
            "elicitation, roots."
        ),
    )
    def primitives() -> str:
        return _read_resource("primitives.md")

    @mcp.resource(
        "glimpse://what-servers-can-see",
        name="What servers can see",
        mime_type="text/markdown",
        description=(
            "Why introspect_mcp_context needs an agent-supplied snapshot: the server-vs-agent vantage gap."
        ),
    )
    def what_servers_can_see() -> str:
        return _read_resource("what-servers-can-see.md")

    @mcp.resource(
        "glimpse://capabilities",
        name="MCP capability negotiation",
        mime_type="text/markdown",
        description="The capability-negotiation matrix exchanged at initialize.",
    )
    def capabilities() -> str:
        return _read_resource("capabilities.md")

    @mcp.resource(
        "glimpse://protocol-versions",
        name="MCP protocol versions",
        mime_type="text/markdown",
        description="MCP protocol version history and how negotiation works.",
    )
    def protocol_versions() -> str:
        return _read_resource("protocol-versions.md")

    @mcp.resource(
        manifest.UI_RESOURCE_URI,
        name="MCP Glimpse",
        mime_type="text/html;profile=mcp-app",
        description="Interactive visual glimpse of your MCP/agent context.",
        meta=_RESOURCE_UI_META,
    )
    def glimpse_app() -> str:
        if manifest.APP_DIST.exists():
            return manifest.APP_DIST.read_text(encoding="utf-8")
        return _APP_PLACEHOLDER

    # --- Health / version routes ---------------------------------------------------------

    @mcp.custom_route("/livez", methods=["GET"])
    async def livez(_request: Request) -> PlainTextResponse:
        return PlainTextResponse("ok")

    @mcp.custom_route("/readyz", methods=["GET"])
    async def readyz(_request: Request) -> JSONResponse:
        # Schema sentinel (kit §13a-3): no injected param may leak into a tool's input schema.
        leaked: list[str] = []
        for tool in await mcp.list_tools():
            props = (tool.inputSchema or {}).get("properties", {})
            leaked += [f"{tool.name}.{p}" for p in ("ctx", "self", "request") if p in props]
        app_built = manifest.APP_DIST.exists()
        ok = not leaked
        return JSONResponse(
            {"status": "ready" if ok else "degraded", "appBuilt": app_built, "schemaLeaks": leaked},
            status_code=200 if ok else 503,
        )

    @mcp.custom_route("/version", methods=["GET"])
    async def version(_request: Request) -> JSONResponse:
        return JSONResponse({"name": "mcp-glimpse", "version": manifest.version()})

    return mcp
