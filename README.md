# mcp-glimpse

**Point your agent at itself.** `mcp-glimpse` is an open-source [MCP](https://modelcontextprotocol.io)
server that lets any agent — and its human — *see* its own environment: every connected MCP server,
every tool and its declared annotations, the negotiated capabilities, the context window, the session,
and the wire. It renders the picture into a self-contained two-tab App and, over stdio, works in any
local MCP host.

It is also a showcase: one Python/FastMCP server that exercises **every** MCP primitive honestly, is the
best-annotated server its users have, and was built end-to-end by an AI fleet.

## 60-second quickstart

Run it locally over stdio with [`uv`](https://docs.astral.sh/uv/) — no install:

```bash
uvx mcp-glimpse
```

Host config:

```json
{ "command": "uvx", "args": ["mcp-glimpse"] }
```

Or connect the hosted, stateful Streamable HTTP endpoint:

```text
https://mcp.mcpglimpse.com/mcp
```

Then ask your agent to run **`introspect_mcp_context`** — with a snapshot of everything it can see for
the full panoramic view, or with no argument for the server-only view.

## The tool surface (small on purpose)

| Tool | What it does |
|---|---|
| `introspect_mcp_context` | THE tool. Renders your MCP/agent context into the App. Optional `snapshot_json` → full panorama across all your servers; omit it → server-only view. Read-only, idempotent, annotated. |
| `submit_feedback` | Durable feedback / feature-request / bug channel. Elicitation-confirmed when the client supports it; degrades gracefully. |
| `share_context_card` | Publishes an anonymized "Agent Facts" card (aggregate counts only — never tool names) and returns its URL. Elicitation-confirmed before anything is written. |

Every tool declares full annotations (`readOnlyHint` / `destructiveHint` / `idempotentHint` /
`openWorldHint` / `title`).

## Every MCP primitive, demonstrated

| Primitive | How mcp-glimpse uses it |
|---|---|
| Tools | The three above, fully annotated. |
| Prompts | `suggest_explorations`, `full_context_dump`, `compare_vantage_points`, `deep_tool_audit`. |
| Resources | `glimpse://` reference docs (schema, primitives, capabilities, protocol-versions, …) + the `ui://` App. |
| Elicitation | Confirm-before-write on `submit_feedback` / `share_context_card`. |
| Sampling | A one-paragraph "your environment, in prose" narrative, rendered in the App. |
| Roots | Calls `roots/list` and shows your workspace roots. |
| Logging / progress | Server→client log + progress during analysis. |
| Completions | Argument completion for `deep_tool_audit`'s focus. |
| listChanged | Declared honestly (the surface is static). |

## Signature analyses

- **Context-cost accounting** — estimates what your tool *definitions* cost against your context window
  (tiktoken `o200k_base` × a per-model-family correction, shown as an honest range): *"your 178 tools
  consume ~40K of your 200K before you say a word."*
- **Tool-poisoning lens** — heuristic scan of tool descriptions for injection directives, exfiltration
  urges, invisible/bidi Unicode, cross-server shadowing, and suspiciously long descriptions.
- **Consistency lens** — flags tools that declare `readOnlyHint` but read like a write.
- **Vantage gap** — how few tools this server sees vs. how many the agent sees.

## Privacy

Snapshots are analyzed **in memory and never persisted, logged, or sent anywhere.** Only an explicit
`submit_feedback` or `share_context_card` call writes anything, and the card stores aggregate counts
only — never tool names or descriptions. The server is public by design; the "This Connection" tab shows
exactly what a server can and cannot know about you.

## Development

```bash
uv sync --dev          # install
uv run pytest          # test
./scripts/check.sh     # the full verify harness
```

The App view lives in `app/` (Vite + TypeScript, single self-contained file). Its TypeScript types are
generated from the Pydantic wire models (`uv run python scripts/gen_app_types.py`) and drift-gated in CI.

## License

MIT. Built with Claude (an AI-fleet build; see the plans under `docs/superpowers/plans/`).
