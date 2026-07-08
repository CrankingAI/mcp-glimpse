---
title: "MCP protocol versions and capability negotiation"
answer: >-
  MCP is date-versioned as YYYY-MM-DD. At initialize, client and server negotiate
  the highest revision both support, and the server echoes the agreed version
  back. Alongside the version, each side advertises its capabilities — the server
  its tools/prompts/resources, the client its sampling/elicitation/roots — and
  each side uses only what the other declared. Notable revisions include
  2024-11-05, 2025-03-26, and 2025-06-18.
description: >-
  How MCP versions its protocol by date, how client and server negotiate a shared
  version and capabilities at initialize, and which revisions matter.
pubDate: 2026-07-02
order: 7
tags: ["mcp", "protocol", "versioning", "capabilities"]
faqs:
  - question: "How is the MCP protocol versioned?"
    answer: >-
      By date, in YYYY-MM-DD form. Each revision is identified by its release
      date, and client and server negotiate the highest version both support
      during initialize, with the server echoing the agreed version back.
  - question: "What happens during MCP initialize?"
    answer: >-
      The client and server exchange protocol versions and capabilities. They
      settle on the highest shared protocol version, and each advertises what it
      supports so the other only uses features that are actually available.
  - question: "What are the notable MCP protocol revisions?"
    answer: >-
      2024-11-05 was the first widely-adopted revision; 2025-03-26 introduced the
      Streamable HTTP transport and auth guidance; 2025-06-18 brought refinements
      and a broader capability set.
---

MCP evolves, and it does so in a way that's easy to reason about: the protocol is
**date-versioned**. Every revision is identified by its release date in
`YYYY-MM-DD` form — no semantic-version guessing about what "2.3" means, just the
date the spec shipped.

## Negotiation at initialize

The first thing a client and server do when they connect is `initialize`. In that
handshake two things get settled:

1. **The protocol version.** The client proposes a version; the server responds
   with the highest version *both* support, and echoes that agreed version back.
   From then on, both speak that revision.
2. **Capabilities.** Each side advertises what it can do. The server declares
   `tools`, `prompts`, and/or `resources` (with sub-flags like `listChanged` or
   `subscribe`). The client declares `sampling`, `elicitation`, and/or `roots`.
   Each side then uses **only** what the other advertised — see [capability
   negotiation](/learn/server-to-client-capabilities) for what those client-side
   capabilities unlock.

The elegance is that a newer client and an older server (or vice versa) can still
talk: they simply meet at the highest revision they share and use the intersection
of their capabilities.

## Notable revisions

| Version | What it brought |
| --- | --- |
| **2024-11-05** | The first widely-adopted revision. |
| **2025-03-26** | Streamable HTTP transport; authorization guidance. |
| **2025-06-18** | Refinements and a broader capability set. |

## A live example of the vantage gap

Here's a subtle point that connects back to [what a server can
see](/learn/what-can-an-mcp-server-see): the negotiated version is agreed at
`initialize`, but whether a server can *report* it back to you depends on the host
surfacing it. When mcp-glimpse's `introspect_mcp_context` runs with no snapshot, it
reports the negotiated protocol version **when the host surfaces it** — and when
the host doesn't, the field honestly reads *"not surfaced."*

That "not surfaced" is not a bug; it's the vantage limit made visible. A server
knows the version it negotiated, but it can only tell *you* what the host chose to
pass along. It's a small, concrete reminder that a server's view of your
environment is exactly as wide as the host lets it be — and no wider.

To see which version your own client actually negotiated, connect mcp-glimpse and
run `introspect_mcp_context`; the "This Connection" view reports the wire-level
facts a server can observe first-hand.
