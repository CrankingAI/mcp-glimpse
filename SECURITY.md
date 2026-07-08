# Security policy

## Reporting a vulnerability

Please report security issues privately to **<codingoutloud@gmail.com>** rather than opening a public
issue. Include a description, reproduction steps, and the affected version. We aim to acknowledge within
a few business days.

## Scope and posture

- **The MCP endpoint is public by design** (no authentication in v1); the Cloudflare edge and the
  app-level rate limiter are the boundary. See `docs/adr/0001-public-by-design-no-auth-v1.md`.
- **Snapshots are never persisted.** `introspect_mcp_context` analyzes the agent-reported snapshot in
  memory and writes nothing. Only `submit_feedback` and `share_context_card` persist data, and the card
  stores aggregate counts only — never tool names or descriptions.
- The `ui://` App view is a single self-contained file with no runtime external requests, and never sets
  `innerHTML` on tool data.

The **tool-poisoning lens** in the App flags injection/exfiltration/hidden-Unicode patterns in *other*
servers' tool descriptions. It is a heuristic aid for reading your own environment, not a security
guarantee.
