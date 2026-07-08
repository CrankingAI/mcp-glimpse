# Edge — Cloudflare in front of every public surface

The kit's public origins (SWA shell, ACA apps) sit behind a **Cloudflare
proxied edge** by default. The edge is the one place that sees every request —
including the ones no origin log and no client script ever will — so it is
where the kit's **Observability Maximalist From The Start** posture starts:
request-level visibility on static paths, **verified-bot classification**
(free plan), and a single front door for TLS, redirects, caching, and abuse
protection.

Seeded state: `apps/edge/` (the logging Worker), `scripts/cf-zone-init.sh`
(zone config), `scripts/cf-domain-bind.sh` (domain + cert dance),
`infra/modules/edge-logs.bicep` (Azure log plumbing). A repo seeded with
`--edge none` prunes those and records `Edge: none` in `GOAL-STATE.md`; this
doc stays as the record of the decision space.

## Why (the observability gap)

- **SWA serves static content from its own edge** — no per-request access log;
  App Insights covers the Functions tier only; platform metrics are aggregate
  CDN counters with no path/client breakdown.
- **Bots don't run your JS.** `sitemap.xml`, `llms.txt`, `robots.txt`,
  `security.txt`, `/.well-known/*` are fetched by crawlers that never execute
  a beacon — client-side analytics show zero while bots hammer them.
- **ACA logs requests** (`ContainerAppHTTPLogs`) but a `User-Agent` is
  spoofable. Cloudflare's **Verified Bots** signal (reverse-DNS + ASN
  validated, free plan) is the difference between "something claiming to be
  GPTBot" and "GPTBot" — the Worker reads it via the `x-kit-verified-bot`
  / `x-kit-verified-bot-category` headers a zone transform rule stamps from
  `cf.client.bot` / `cf.verified_bot_category` (free plan; `request.cf.botManagement`
  itself is Enterprise Bot Management only).

## Zone posture (what `cf-zone-init.sh` enforces)

| Setting | Value | Why |
|---|---|---|
| DNS records | **Proxied** (orange cloud) CNAME → origin hostname | No proxy, no visibility |
| SSL/TLS mode | **Full (strict)** — never Flexible | Azure serves a valid cert on its default hostname |
| Min TLS | 1.2 | Azure requires ≥1.2; baseline hardening |
| Always Use HTTPS | On | http→https at the edge |
| Cache rule | **Bypass** on watched paths | Worker runs on cache hits anyway; bypass keeps origin logs 1:1 |
| Redirect rule | `www` → apex, 301 | See [site-conventions](site-conventions.md) |
| Transform rule | Stamp `x-kit-verified-bot` / `x-kit-verified-bot-category` from `cf.client.bot` / `cf.verified_bot_category`, unconditionally on every request | Free-plan source of the Worker's verified-bot signal (`request.cf.botManagement` is Enterprise-only); unconditional SET is what makes it anti-spoofing |

### Origin specifics

- **SWA:** validate the custom domain with the **TXT-record method** (CNAME
  validation fights the proxy), or temporarily grey-cloud → validate → flip
  back to proxied. Never override the `Host` header — SWA routes by hostname.
- **ACA:** `asuid.<sub>` TXT + managed cert; managed-cert issuance needs the
  record resolving **directly** (grey-cloud during the dance — DigiCert
  issuance and renewal are blocked by the proxy). `scripts/cf-domain-bind.sh`
  automates the full sequence.
- Double CDN (CF in front of SWA's/ACA's edge) is harmless; if cache behavior
  looks odd, check both layers' cache headers.

## Protection ladder (free baseline, upgrade where needed)

The free tier ships a real abuse boundary at $0 idle — this replaces the old
"Front Door WAF documented-but-not-deployed" posture with a baseline that is
actually on:

| Tier | You get |
|---|---|
| **Free (default)** | Unmetered DDoS (L3/4/7), **Free Managed WAF Ruleset**, **Bot Fight Mode**, **Verified Bots** signal, 5 custom rules + 1 rate-limiting rule |
| **Pro/Business — where needed** | Full managed WAF rulesets, **Super Bot Fight Mode**, unlimited custom + rate-limiting rules; attack score (Business) |
| **Enterprise — where genuinely needed** | **Bot Management** (numeric score 1–99, per-request), advanced rate limiting, Logpush |

Paid tiers are explicit opt-ins in the [operations](operations.md) sense —
document the trade, add deliberately. The app-level rate limiter stays as
defense-in-depth ([rate-limiting](rate-limiting.md)).

**Never challenge verified bots.** Link-preview fetchers (Twitterbot,
facebookexternalhit, LinkedInBot, Slackbot) are verified bots; a custom
WAF/bot rule that fails to exempt `cf.client.bot` silently kills OG link
previews. The OG tags themselves are governed by
[seo-discoverability](seo-discoverability.md) and unaffected by the edge.

## The logging pipeline (two sinks + optional PostHog)

`apps/edge/` runs a Worker on the **watched paths**: `/sitemap.xml`,
`/llms.txt`, `/llms-full.txt`, `/robots.txt`, `/security.txt`,
`/.well-known/*`. It always returns the origin response (`fetch(req)` first);
the Analytics Engine write is a synchronous try/catch, and the Azure and
PostHog sends each sit in their own `ctx.waitUntil(...).catch(...)` —
**fail-open**, a logging outage never touches user traffic.

Retention follows the [EFF DNT policy](https://www.eff.org/dnt-policy): logs
including IP + User-Agent may live **≤ 10 days**; verified bots are not
"users", so bot-scoped analytics may live longer. That forces the split —
enforced in one pure module (`apps/edge/src/record.ts`):

The `Verified`/`BotName` fields the sinks below receive come from
`request.cf.botManagement` on Enterprise Bot Management plans; on every other
plan (the kit default) they come from the `x-kit-verified-bot` /
`x-kit-verified-bot-category` headers the zone transform rule
(`cf-zone-init.sh`) stamps from `cf.client.bot` / `cf.verified_bot_category` —
see `resolveBot` in `apps/edge/src/record.ts`. **The transform rule is
load-bearing:** on non-Enterprise plans, deploying the Worker without having
run `cf-zone-init.sh` means those headers arrive client-supplied and
unstripped — run the zone posture before (or with) the first Worker deploy.

| Sink | Retention | Receives |
|---|---|---|
| **Log Analytics** `EdgeHits_CL` (Logs Ingestion API) | **10 days** (table-level) | Everything: IP, UA, path, status, geo, verified, bot name |
| **Analytics Engine** `edge_hits` | ~3 months (fixed) | DNT-safe: path, method, status, country, colo, verified, bot name; **UA only on verified-bot hits; never IP** |
| **PostHog** (optional) | per workspace | DNT-safe fields; `$geoip_*` stamped from `request.cf` with `$geoip_disable: true`; `$process_person_profile: false`; never IP; UA verified-only |

The Azure leg authenticates with **Entra client credentials** (a CF Worker
cannot hold a managed identity) — the app registration gets **Monitoring
Metrics Publisher** on the DCR; see [security](security.md) for the exception
note. Secrets go in via `wrangler secret put`, never in `wrangler.jsonc`.
**Multi-tenant trap (hit live):** create the app registration in the tenant of
the subscription that holds the DCR — `az ad app create` uses the CLI's
*current* subscription context, and a role assignment with an explicit
`principalType` will silently "succeed" for a ghost principal from another
tenant. The symptom is `AADSTS700016` at token time.

**Widening to `/*`** (full edge request log) is a documented opt-in: edit the
`routes` in `apps/edge/wrangler.jsonc`. Mind quotas — Workers free tier is
100k req/day and Analytics Engine 100k writes/day, both **account-wide pools
shared across every zone/Worker in the account**; the 10-day sink keeps even
full-path logging DNT-compliant.

**Set `request_limit_fail_open: true` on every Worker route** (API or dash —
not expressible in `wrangler.jsonc`; re-apply after route-recreating deploys).
With it, exceeding the free daily cap bypasses the Worker — the origin serves
and you lose only that day's logging tail; without it the watched paths return
error 1027. Workers Paid ($5/mo, whole account) removes the cap entirely —
that flat fee is the only payment cliff in this design.

## Consuming the data

| Data | Programmatic | Interactive |
|---|---|---|
| `EdgeHits_CL` (10-day, exact) | `az monitor log-analytics query`, Azure Monitor Query SDK | Portal Logs blade + workbooks (`round()`, never `toint()` — [observability](observability.md)); `app-insights` MCP ([.mcp.json](../.mcp.json)) |
| `edge_hits` (3-month trends) | Analytics Engine **SQL API** (`POST /accounts/{id}/analytics_engine/sql`) | `cloudflare-observability` MCP; Grafana AE data-source plugin |
| Zone-wide (sampled) | **GraphQL Analytics API** (`httpRequestsAdaptiveGroups`) | CF dashboard Analytics |
| PostHog | HogQL over the API | PostHog insights (geo maps work — `$geoip_*` is stamped); `posthog` MCP |
| Worker runtime | `wrangler tail` | Workers Logs in the CF dash |

Example cuts (AE SQL API; blob positions match
`apps/edge/src/record.ts:toAnalyticsEngine`):

```sql
-- Who's reading llms.txt? (verified AI crawlers; blob2 = UA, verified-only)
SELECT blob2 AS ua, blob6 AS bot, count() AS hits
FROM edge_hits
WHERE blob1 = '/llms.txt' AND timestamp > NOW() - INTERVAL '30' DAY
GROUP BY ua, bot ORDER BY hits DESC;
```

```kql
// Recon on security.txt with full fidelity — 10-day window is the point
EdgeHits_CL
| where TimeGenerated > ago(10d) and Path == "/security.txt"
  and Verified == false
| summarize hits = count() by Ip, UserAgent
| order by hits desc
```

```kql
// Edge view joined to origin view (the OTel-maximalism payoff)
EdgeHits_CL
| where TimeGenerated > ago(24h)
| join kind=leftouter (ContainerAppHTTPLogs | where TimeGenerated > ago(24h))
    on $left.Path == $right.Path
| project TimeGenerated, Path, Status, Verified, BotName, RevisionName
```

## Automation

The kit ethos applied to Cloudflare: **agents do the work, humans make the
decisions.** The only human steps are bootstrap:

1. Create the CF account, add the zone, delegate nameservers at the registrar.
2. Approve **one OAuth prompt** (preferred — `cf-zone-init.sh --mint-tokens`
   then mints the scoped tokens itself), **or** mint two least-privilege
   tokens by hand in the dashboard:
   - *zone-config token* — `DNS Write`, `Zone Read`, `Zone Settings Write`,
     `Cache Settings Write`, `Dynamic URL Redirects Write`,
     `Zone Transform Rules Write`, scoped to this zone. (`Zone Read` is what
     lets this token do the account-id self-lookup; the bootstrap token cannot
     read zones. Exact API group names, verified live — dashboard labels
     differ.)
   - *worker-deploy token* — `Workers Scripts Write` + `Workers Routes Write`,
     account-scoped.
3. Enable **Workers Analytics Engine** once for the account (dash → Workers →
   Analytics Engine — create the `edge_hits` dataset / `EDGE_HITS` binding
   there while you are at it). Until this one-time enable, any deploy carrying
   an AE binding fails with API error `10089` (verified live).

Everything past that line is scripted or CI:

- `scripts/cf-zone-init.sh` — idempotent zone posture (table above) +
  `--mint-tokens`.
- `scripts/cf-domain-bind.sh` — grey-cloud CNAME → Azure-side validation +
  managed cert → poll → flip `proxied=true`. Both control planes, resumable.
- **CI leg:** the `v*` tag-push workflow runs `wrangler deploy` for
  `apps/edge/` (via `cloudflare/wrangler-action`) after `azd deploy`, plus
  `wrangler secret put` for the Worker's Azure credentials.
- Token storage: **secrets** for the tokens (`CF_API_TOKEN`,
  `CF_WORKER_DEPLOY_TOKEN`); **GH Actions variables** for the ids
  (`CF_ACCOUNT_ID`, `CF_ZONE_ID`) — account/zone ids are not secret, and the
  deploy workflow reads them as `vars.*`. The CI leg's
  `cloudflare/wrangler-action` authenticates with `CF_WORKER_DEPLOY_TOKEN` (the
  account-scoped Workers token) — never the zone-config token. Cloudflare has
  **no OIDC federation**, so the tokens are a documented exception to the
  no-cloud-secrets-in-GitHub rule — scoped,
  least-privilege tokens only ([security](security.md)).

**Division of labor:** scripts + CI are the canonical provisioning path
(deterministic, idempotent, reviewable, headless). MCP servers
(`cloudflare-docs` on by default; `cloudflare`, `cloudflare-observability`,
`posthog` as commented opt-ins in [.mcp.json](../.mcp.json)) are the
interactive layer — diagnosis, queries, one-off ops. Write-capable MCP servers
never become the provisioning mechanism of record.

## IaC boundary

Azure resources are **azd + AVM + Bicep, always** — Terraform never touches
the Azure side. The CF side is scripts by kit default (the API surface here is
a handful of idempotent calls); Terraform for the **CF side only** is an
acceptable per-repo alternative if the repo already runs it (provider v5
renamed most resources — verify against the registry).

## Related

- [observability](observability.md) — the app telemetry pipeline; edge
  telemetry joins it in Log Analytics.
- [site-conventions](site-conventions.md) — the watched files themselves +
  `dnt-policy.txt`.
- [security](security.md) — CF token storage; client-credentials exception.
- [operations](operations.md) — explicit-opt-in cost posture.
- [watch-list](watch-list.md) — AI Crawl Control / pay-per-crawl.
