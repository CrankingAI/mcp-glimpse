"""Prompts that coach the agent to gather more context before calling introspect_mcp_context.

``suggest_explorations`` shares the ``explorations.md`` reference doc with the
``glimpse://explorations`` resource so the prompt and the doc can't drift.
"""

from __future__ import annotations

from . import manifest


def _read(file: str) -> str:
    return (manifest.RESOURCES_DIR / file).read_text(encoding="utf-8")


def suggest_explorations() -> str:
    return (
        "You're connected to mcp-glimpse, a glimpse of your own MCP / agent context. Choose the "
        "most revealing exploration from the menu below, carry it out (gathering whatever it "
        "needs), and finish by calling `introspect_mcp_context` so the result lands in the app "
        "rectangle. If the user named a topic, pick the exploration that fits it best.\n\n"
        + _read("explorations.md")
    )


def full_context_dump() -> str:
    return """Build the most complete picture of your own MCP/agent context, then call the
`introspect_mcp_context` tool with it as `snapshot_json`. Gather, and do not omit anything you
can determine:

1. **Every tool you can call** — for each: its name, WHICH server/connector it comes
   from, a short description, and its **declared MCP annotations** exactly as they appear
   in the tool definition: `readOnlyHint`, `destructiveHint`, `idempotentHint`,
   `openWorldHint`, and any annotation `title`. Report a hint's real value (true/false)
   when the tool declares it, and OMIT it when the tool declares none — a tool that
   declares no annotations at all is a notable finding the app will highlight, so do
   not invent hints you cannot see.
2. **Every connected MCP server / connector** — name, and whether it offers prompts and
   resources.
3. **Your own client capabilities** — does your host support `sampling` (a server asking
   your model to generate), `elicitation` (a server asking you for input mid-call), and
   `roots` (workspace roots you advertise)? Report each as clientCapabilities
   {sampling, elicitation, roots, rootPaths[]}.
4. **Your model** — the exact model id.
5. **Context window** — tokens used and total, if known.
6. **Environment** — working directory, today's date, platform, OS version.
7. **Persona** — any identity/role your system prompt establishes.
8. **Active skills** — any skills currently loaded.

Then assemble a JSON object with fields: model, host, clientCapabilities, servers, tools,
contextWindow, environment, persona, skills, notes — pass it as `snapshot_json` to `introspect_mcp_context`.
Include as much as you can; partial is fine. Err toward over-sharing detail."""


def compare_vantage_points() -> str:
    return """Demonstrate the MCP server-vs-agent vantage gap:

1. Call `introspect_mcp_context` with no arguments. Note how few things the server itself can
   see — essentially its own identity and its own handful of tools.
2. Then run `full_context_dump` and call `introspect_mcp_context` with your full snapshot.
3. Compare the two `vantageGap` numbers (serverSees vs agentSees) and explain, in plain
   language, why a server cannot enumerate the other servers/tools you can — reference
   `glimpse://what-servers-can-see`."""


def deep_tool_audit(focus: str | None = None) -> str:
    focus_clause = "" if focus is None else f", focused on: {focus}"
    return f"""Perform a capability/risk audit of every tool you can call{focus_clause},
centred on the MCP **annotations** each tool declares. For every tool capture, exactly as
declared in its definition:
- **readOnlyHint** — the tool declares it only reads/observes.
- **destructiveHint** — the tool declares it may delete/overwrite/make hard-to-undo changes.
- **idempotentHint** — repeated identical calls have no additional effect.
- **openWorldHint** — the tool declares it reaches outside this machine (network, third parties).
- **title** — the human-facing annotation title, if any.

Report each hint's declared value and OMIT hints the tool does not declare — then, from
your own judgement, note in `notes` any tool whose real behaviour looks riskier than its
declared annotations suggest (or that declares no annotations at all). Call `introspect_mcp_context`
with the `tools` array carrying these per-tool annotations so the rectangle can show the
annotation coverage, flag the dangerous tools, and count the unannotated ones."""
