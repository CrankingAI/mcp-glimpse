# MCP protocol versions

The protocol is date-versioned (`YYYY-MM-DD`). Client and server negotiate the highest version
both support during `initialize`; the server echoes the agreed version back.

Notable revisions:

- **2024-11-05** — first widely-adopted revision.
- **2025-03-26** — Streamable HTTP transport; auth guidance.
- **2025-06-18** — refinements; broader capability set.

`introspect_mcp_context` (no snapshot) reports the negotiated version when the host surfaces it; when it doesn't,
the field shows "not surfaced" — a live example of the server vantage limit.
