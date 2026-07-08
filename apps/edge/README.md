# apps/edge — Cloudflare edge Worker

Logs every watched-path hit (`/sitemap.xml`, `llms.txt`, `robots.txt`,
`security.txt`, `/.well-known/*`) with verified-bot classification, into three
sinks with the DNT field-split enforced in `src/record.ts`. Fail-open: the
origin response always wins. Convention + queries: [docs/edge.md](../../docs/edge.md).

Unlike `apps/web` and `apps/app`, this is **not a placeholder** — the Worker
is origin-agnostic and ships ready. Fill `mcpglimpse.com`/`glimpse` (seed-init
`--substitute` does it), deploy with `wrangler deploy`.

- Sinks: Analytics Engine `edge_hits` (always) · Azure `EdgeHits_CL` via Logs
  Ingestion (toggle `AZURE_ENABLED`) · PostHog (toggle `POSTHOG_ENABLED`).
- Secrets via `wrangler secret put` — names listed in `wrangler.jsonc`.
- Azure plumbing (DCE/DCR/table, 10-day retention):
  `infra/modules/edge-logs.bicep`; its outputs feed the `AZURE_*` secrets.
- Zone posture + domain binding: `scripts/cf-zone-init.sh`,
  `scripts/cf-domain-bind.sh`.
- Widening routes to `/*` is a documented opt-in (docs/edge.md — quotas).
