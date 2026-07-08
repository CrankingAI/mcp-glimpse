# 0002 — www is canonical; apex redirects to www

- **Status:** Accepted
- **Date:** 2026-07-07
- **Deciders:** Bill Wilder (CrankingAI)

## Context

The kit's `docs/site-conventions.md` bakes **apex as canonical** and redirects
`www.{{DOMAIN}} → apex` (301, at the Cloudflare edge via `scripts/cf-zone-init.sh`).
The mcp-glimpse brief (§6) specifies the opposite: the marketing/Learn site is served
at `www.mcpglimpse.com`, the MCP endpoint at `mcp.mcpglimpse.com`, and the **apex
`mcpglimpse.com` redirects → www**. Running two subdomains (`www`, `mcp`) with a bare
apex that only redirects is a clean split of concerns; `www` as the canonical
marketing host is the brief's explicit choice.

## Decision

We will treat **`www.mcpglimpse.com` as the canonical marketing host** and redirect
the apex `mcpglimpse.com → www.mcpglimpse.com` (301, at the Cloudflare edge). This
**inverts** the kit default. `scripts/cf-zone-init.sh`'s redirect rule direction is
adjusted for this repo accordingly; canonical URLs, the sitemap, JSON-LD `url`
fields, and OG `og:url` all use the `www` host. `mcp.mcpglimpse.com` is the MCP
endpoint (its own subdomain, not affected by the redirect).

## Consequences

- **Easier:** clear host-per-concern split (`www` marketing, `mcp` protocol);
  matches the brief and the DNS plan already in flight; `www` canonical is
  unambiguous for answer engines and social unfurls.
- **Harder / locked in:** we depart from the kit's zone-init default, so
  `cf-zone-init.sh` needs a repo-local adjustment (apex→www, not www→apex) and any
  kit re-seed/sync must not silently revert it. All canonical/OG/sitemap URLs must
  consistently use `www` (a mix of apex and www dilutes SEO and can double-index).
- **Revisit when:** the kit changes its canonical-host convention, or we decide to
  serve marketing from the apex. Any change here is a coordinated edit of the CF
  redirect rule + every canonical/OG/sitemap URL + JSON-LD.
