# MCP primitives — a field glossary

- **Tools** — model-invoked functions the server exposes (e.g. `introspect_mcp_context`). The client's
  model decides when to call them; each has a JSON-Schema input.
- **Prompts** — user-selected, parameterized message templates the server offers (e.g.
  `full_context_dump`). User-controlled: surfaced for a human/agent to pick, not auto-called.
- **Resources** — addressable, readable content the server publishes at a URI (e.g.
  `glimpse://primitives`). Application-controlled: the client reads them for context.
- **Sampling** — the server asking the client's model to generate. Requires an interactive
  (stateful) session; unavailable in stateless HTTP.
- **Elicitation** — the server prompting the user for input mid-tool-call. Also interactive-only.
- **Roots** — filesystem/workspace roots the client advertises to the server.

mcp-glimpse uses the first three. The last three need a stateful session and are out of scope.
