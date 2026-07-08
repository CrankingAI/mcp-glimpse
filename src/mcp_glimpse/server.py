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

import json
import logging
import os

from mcp.server.fastmcp import Context, FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import Completion, CompletionArgument, PromptReference, ToolAnnotations
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse, Response

from . import card as card_module
from . import connection, manifest, prompts
from .analyzer import analyze
from .card import CardStore, create_card_store
from .feedback import FeedbackStore, create_feedback_store
from .model import GlimpseReport
from .parser import parse
from .primitives import best_effort, confirm, fetch_roots, narrate

# Argument-completion options for the deep_tool_audit prompt's `focus` arg.
_AUDIT_FOCUS_OPTIONS = [
    "annotations", "danger", "duplicates", "injection", "exfiltration",
    "network egress", "unannotated", "shadowing",
]

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


def build_server(
    feedback: FeedbackStore | None = None, cards: CardStore | None = None
) -> FastMCP:
    store = feedback if feedback is not None else create_feedback_store()
    card_store = cards if cards is not None else create_card_store()

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
    async def introspect_mcp_context(
        ctx: Context, snapshot_json: str | dict | None = None
    ) -> str:
        # Accept either a JSON string or an already-parsed object: FastMCP pre-parses any
        # JSON-looking string argument into a dict before it reaches the tool, so a str-only
        # type would reject the natural input (an agent passing the JSON object). Normalize.
        if isinstance(snapshot_json, (dict, list)):
            snapshot_json = json.dumps(snapshot_json)
        # Logging + progress are demonstrators (server->client) — best-effort, never blocking.
        await best_effort(ctx.info, "mcp-glimpse: analyzing your MCP context")
        await best_effort(ctx.report_progress, 0.15, 1.0, "parsing snapshot")
        parsed = parse(snapshot_json)
        conn = connection.observe(ctx)
        conn.roots = await fetch_roots(ctx)  # roots/list demonstrator (degrades to [])
        await best_effort(ctx.report_progress, 0.55, 1.0, "computing analysis")
        analysis = analyze(parsed.snapshot, conn)
        summary_line = (
            f"{analysis.total_tools} tools across {analysis.total_servers} servers; "
            f"{analysis.dangerous_tool_count} flagged dangerous; "
            f"{analysis.annotated_tool_count}/{analysis.total_tools} annotated."
        )
        narrative = await narrate(ctx, summary_line)  # sampling demonstrator (degrades to None)
        await best_effort(ctx.report_progress, 1.0, 1.0, "done")
        logger.info(
            "introspect_mcp_context: agentTools=%s serverTools=%s warnings=%s narrated=%s roots=%s",
            analysis.total_tools,
            analysis.vantage_gap.server_sees,
            len(parsed.warnings),
            narrative is not None,
            len(conn.roots),
        )
        report = GlimpseReport(
            source="introspect_mcp_context",
            warnings=parsed.warnings,
            snapshot=parsed.snapshot,
            connection=conn,
            analysis=analysis,
            narrative=narrative,
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
    async def submit_feedback(
        ctx: Context,
        kind: str,
        summary: str,
        detail: str | None = None,
        context: str | None = None,
    ) -> dict[str, str]:
        logger.info("submit_feedback: kind=%s", kind)
        # Elicitation demonstrator: confirm before writing when the client supports it; degrade to
        # record-unconfirmed otherwise (folds in mcp-lens-aspnet's confirm_and_note). The write is
        # OUTSIDE the elicit path and guarded, so a confirmed write is never double-attempted and a
        # backend failure never masquerades as an elicitation failure.
        state = await confirm(ctx, f'Record this {kind}: "{(summary or "")[:140]}" now?')
        if state == "declined":
            return {"id": "", "status": "not recorded (declined)", "elicitation": "declined"}
        try:
            recorded = dict(store.record(kind, summary, detail, context))
        except Exception:
            logger.exception("submit_feedback: store write failed")
            return {"id": "", "status": "error: feedback not stored (backend unavailable)"}
        # 'unsupported'/'failed' -> unconfirmed but still recorded (never a silent no-op).
        recorded["elicitation"] = "confirmed" if state == "confirmed" else "unconfirmed"
        return recorded

    @mcp.tool(
        name="share_context_card",
        description=(
            "Publish an anonymized 'Agent Facts' summary card and return its URL. This WRITES: it "
            "persists ONLY aggregate counts (servers, tools, destructive count, annotation "
            "coverage, capability flags, and the estimated tool-definition token cost) — never tool "
            "names or descriptions. Elicitation-confirmed before anything is saved. Pass the same "
            "snapshot_json you would give introspect_mcp_context; the aggregates are derived "
            "server-side. The returned page carries an OG image that unfurls on X/LinkedIn/Slack."
        ),
        annotations=ToolAnnotations(
            title="Share an anonymized Agent Facts card",
            readOnlyHint=False,       # it writes
            destructiveHint=False,    # but does not delete/overwrite
            idempotentHint=False,     # each call mints a new card id
            openWorldHint=False,
        ),
        structured_output=False,
    )
    async def share_context_card(
        ctx: Context, snapshot_json: str | dict | None = None
    ) -> dict[str, str]:
        if isinstance(snapshot_json, (dict, list)):
            snapshot_json = json.dumps(snapshot_json)
        aggregates = card_module.aggregates_from_snapshot_json(snapshot_json)
        # Confirm before persisting. An explicit decline blocks publication; when the client can't
        # elicit (or elicitation fails), the card is aggregate-only so we still publish but say so.
        state = await confirm(
            ctx, "Publish an anonymized summary card (aggregate counts only, no tool names)?"
        )
        if state == "declined":
            return {"status": "not published (declined)", "url": ""}
        try:
            card = card_store.put(aggregates)
        except Exception:
            logger.exception("share_context_card: card write failed")
            return {"status": "error: card not stored (backend unavailable)", "url": ""}
        logger.info("share_context_card: id=%s tools=%s", card.id, card.tools)
        return {
            "status": "published" if state == "confirmed" else "published (unconfirmed)",
            "id": card.id,
            "url": f"https://mcpglimpse.com/c/{card.id}",
            "elicitation": "confirmed" if state == "confirmed" else "unconfirmed",
        }

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

    # --- Share-card OG image -------------------------------------------------------------

    @mcp.custom_route("/og/{card_id}", methods=["GET"])
    async def og_image(request: Request) -> Response:
        card = card_store.get(request.path_params["card_id"])
        if card is None:
            return PlainTextResponse("card not found", status_code=404)
        try:
            png = card_module.render_og_png(card)
        except Exception:
            logger.exception("og_image: render failed for %s", card.id)
            return PlainTextResponse("card image unavailable", status_code=500)
        return Response(png, media_type="image/png", headers={"Cache-Control": "public, max-age=86400"})

    # --- Completions ---------------------------------------------------------------------

    @mcp.completion()
    async def complete(
        ref: PromptReference, argument: CompletionArgument, _context: object
    ) -> Completion | None:
        # Argument completion for the deep_tool_audit prompt's `focus` value.
        if getattr(ref, "name", None) == "deep_tool_audit" and argument.name == "focus":
            prefix = (argument.value or "").lower()
            values = [o for o in _AUDIT_FOCUS_OPTIONS if o.lower().startswith(prefix)]
            return Completion(values=values, total=len(values), hasMore=False)
        return None

    return mcp
