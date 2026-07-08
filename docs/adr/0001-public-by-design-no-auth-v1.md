# 0001 — MCP endpoint is public by design (no auth in v1)

- **Status:** Accepted
- **Date:** 2026-07-07
- **Deciders:** Bill Wilder (CrankingAI)

## Context

`rules/backend-mcp.md` recommends every MCP server be an OAuth2 resource server
(Descope DCR): validate a bearer token per request, advertise Protected Resource
Metadata at `/.well-known/oauth-protected-resource`, return `WWW-Authenticate` on
401. mcp-glimpse is a read-only introspection tool whose entire thesis (the App's
"This Connection" tab) is teaching visitors *what a server can and cannot see about
them*. It analyzes agent-reported snapshots in memory and persists nothing except
explicit `submit_feedback` / `share_context_card` writes. A zero-friction "connect
and run" path is a stated acceptance goal (cold visitor → first introspection under
two minutes). The brief (§4, §8, §12) frames auth as a documented fast-follow, and
Tab 2 literally says "public by design."

## Decision

We will ship v1 with **no authentication** on `/mcp`; the endpoint is public by
design and the Cloudflare edge + the app-level rate limiter are the boundary. The
"This Connection" tab states "public by design" as a feature, not an omission.
OAuth2 resource-server auth (Descope DCR per `rules/backend-mcp.md`, plus
`/.well-known/oauth-protected-resource` and auth-introspection in the report) is a
backlog item, not v1. `/livez` `/readyz` `/version` remain unauthenticated
regardless.

## Consequences

- **Easier:** the connect flow has no registration step; the two-minute acceptance
  path is achievable; no Descope provisioning (Management API, MCP-server console
  object, issuer-validation footgun from backlog §11c) is on the v1 critical path.
- **Harder / locked in:** anyone can call the tools; abuse control rests entirely on
  the edge and rate limiter. Because tool/parameter names are an append-only
  contract, adding auth later must not rename the surface — only add the PRM
  document and the `WWW-Authenticate` challenge.
- **Revisit when:** we add any tool that writes non-anonymous or user-scoped data,
  observe abuse the edge cannot absorb, or a host ecosystem requires authenticated
  servers. At that point implement the `rules/backend-mcp.md` Descope path and flip
  Tab 2's copy from "public by design" to the authenticated posture.
