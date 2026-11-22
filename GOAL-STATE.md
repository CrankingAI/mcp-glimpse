# Goal state

What this repo is configured to be. High-level by design — the depth lives in the
linked rule/convention files. This is the source of truth a human reviews (render
it in Preview) and the seeding/reboot skills read and write.

> **Machine-read fields** (`seed-init.sh --from-goal-state` / reboot skills parse
> these): the **Web app-layer** Selected cell (`react-router` | `nextjs` | `none`),
> each **backend-topology Host** cell (`functions` | `container-apps`; `Static Web
> Apps` and `—` are ignored), the **Edge** Selected cell (`cloudflare` | `none`),
> and a component row whose name contains `MCP` (turns on the MCP interface). Keep
> those cells as bare tokens.

| Axis | Selected | Detail | Why |
|------|----------|--------|-----|
| Web app-layer | none | [frontend-web](rules/frontend-web.md) | www is a static Astro marketing/Learn shell; no SPA app layer in v1 |
| Mobile | no | [frontend-mobile](rules/frontend-mobile.md) | no mobile surface |
| Persistence | storage | [persistence](docs/persistence.md) | Azure Table Storage (managed identity) for `submit_feedback` and share cards; snapshots are never persisted |
| Auth | none | [auth](docs/auth.md) | public by design in v1 — [ADR 0001](docs/adr/0001-public-by-design-no-auth-v1.md); Descope OAuth2 is a backlog item |
| Agentic monetization | none | [agentic-commerce](docs/agentic-commerce.md) | free, public tool |
| Cloud / provider | azure (plus cloudflare) | [deployment](docs/deployment.md) | Static Web Apps behind the Cloudflare proxied edge; ACA direct (DNS-only) |
| Edge | cloudflare | [edge](docs/edge.md) | proxied edge + logging Worker on `www` watched paths; `mcp` stays DNS-only so its ACA managed cert can renew (the proxy blocks DigiCert) |
| Environments & naming | ORG=`EffAz` ENV=`prod` PROJECT=`glimpse` region=`eastus` domain=`mcpglimpse.com` | [deployment](docs/deployment.md) | naming scheme; apex → www canonical ([ADR 0002](docs/adr/0002-www-canonical-apex-redirects-to-www.md)) |

## Backend topology

mcp-glimpse's only backend is the MCP tool server on a Container Apps host; the
public web shell is Static Web Apps. There is no separate human HTTP API.

| Component | Host | Shares host with | Detail |
|-----------|------|------------------|--------|
| Public web shell | Static Web Apps | — | [frontend-web](rules/frontend-web.md) |
| MCP tool server | container-apps | — | [backend-mcp](rules/backend-mcp.md) |

## Domains

| Host | Serves |
|------|--------|
| `mcp.mcpglimpse.com` | the MCP endpoint (`/mcp`) — ACA custom domain + cert |
| `www.mcpglimpse.com` | marketing + Learn site (canonical) |
| apex `mcpglimpse.com` | 301 redirect → `www` ([ADR 0002](docs/adr/0002-www-canonical-apex-redirects-to-www.md)) |

## Design

Fleet default **Paper & Proof** ([packages/tokens/DESIGN.md](packages/tokens/DESIGN.md));
`tokens.json → theme.css` via the token pipeline, consumed at the shadcn `:root`
seam. Per-repo overrides go through the `design-consultation` skill and are recorded
in that DESIGN.md's Decisions Log (never a silent drift; the token-drift gate enforces it).

## Fixed (not choices)

Health `/livez`+`/readyz`, `/version` from `VERSION`, OTel → App Insights, RFC 9457
Problem Details, feature flags (default off). The cross-cutting contract every host
honors. Additionally binding for the MCP surface: stateful Streamable HTTP; camelCase
wire contract (`by_alias` + `exclude_none`) with a contract-snapshot CI gate;
tool/parameter names are append-only; `MCP_ALLOWED_HOSTS` set; `minReplicas 0`
(scale-to-zero, estate decision F-0009 — cold start accepted, kept short by a fast
readiness probe), single replica.
