# Application auth / identity

Application and user authentication is **situationally sensitive**: it is chosen per
backend and **confirmed per repo during seeding** — a confirmation gate, never a
silently baked default. This doc is the full matrix the seeding gate draws from.

## Workforce vs consumer

| Audience | Identity provider | Notes |
|---|---|---|
| **Workforce** (employees, internal) | **Entra ID** | documented; examples lean here |
| **Consumer / CIAM** | **Entra External ID** | **back-burnered** — available but not currently used; **NOT Azure AD B2C** (legacy) |
| **MCP tool server** | **Descope** (free tier, DCR) | recommended authority for MCP; see [backend-mcp.md](../rules/backend-mcp.md) |

Document both, but **examples lean workforce / Entra ID** because it is the common
case. Entra External ID is **back-burnered** (documented for consumer-facing apps, but
not currently in use); never start a new Azure AD B2C tenant.

## Mechanism: Easy Auth first, MSAL/JWT when you outgrow it

- **Easy Auth is the default mechanism** — platform built-in auth on SWA / ACA.
  No auth library in app code; the platform injects the authenticated
  principal. This is the often-right answer.
- **MSAL / JWT** is the documented path for **when you outgrow Easy Auth** — granular
  scopes, custom token validation, multi-tenant nuance, or APIs that must validate
  bearer tokens themselves.

**Easy Auth is first-class for securing the human-facing services** — it is how the
public shell / SPA reach the backend (front-to-back) on SWA / ACA. It is
separate from MCP auth: an **MCP** server is an OAuth2 resource server (authority
**Descope**, see [backend-mcp.md](../rules/backend-mcp.md)), and Descope's session SDK
(`ValidateSession` / `RefreshSession`) is the **web/SPA session** tool — never wired into
an MCP server.

## Per-backend default

The default **leans to platform Easy Auth**, with **OAuth2 resource-server for MCP**:

| Backend | Default auth |
|---|---|
| SWA (public shell + linked API) | **Easy Auth** |
| Container Apps | **Easy Auth** (ACA built-in auth) |
| MCP | **OAuth2 resource-server**, authority **Descope** (free tier, DCR) — see [backend-mcp.md](../rules/backend-mcp.md) |

## Confirmation gate (not a silent default)

Because auth is situationally sensitive, the **seed / creation process explicitly
confirms the auth choice per repo**. Do not assume a default landed silently — the
chosen audience (workforce / consumer) and mechanism (Easy Auth / MSAL-JWT / MCP
OAuth2) are attested during seeding, then recorded in the repo — the
`GOAL-STATE.md` auth row, plus an ADR ([docs/adr](adr/README.md)) for any
non-default choice.

## Related

- [security](security.md) — Key Vault refs, managed identity, secret rotation.
- [site-conventions](site-conventions.md) — `/.well-known/change-password` when the
  app has authentication.
- [rules/backend-mcp.md](../rules/backend-mcp.md) — MCP OAuth2 resource-server
  specifics.
