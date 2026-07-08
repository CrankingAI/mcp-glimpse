# AGENTS.md

Single source of truth for AI agents (Codex, Copilot, Cursor, Gemini, Claude Code)
working in this repo. This file is canonical; every other agent file points here.

## Standing directive

Prefer modern, idiomatic patterns for the stack in use: Azure + .NET 10,
Astro 6 with Tailwind v4 + React islands (public shell), Vite + React SPA
(app layer). "Modern & idiomatic" is a standing rule, not a one-time choice —
bias to the strongest mid-2026 defaults.

**Idiomatic means the _current_ major, not the most familiar one.** Recall of
"idiomatic" skews to whatever major a tool dominated with for years — so left
implicit, generated code silently lands on a superseded version (the classic trap:
`xunit` v2 instead of `xunit.v3`). Therefore: **name the major, and verify the
latest stable at seed time from the registry — never from memory.** Check NuGet /
npm and the official docs (the [Microsoft Learn MCP](.mcp.json) is wired in for
.NET/Azure) before pinning. A version floor in this kit is a _minimum_ ("not below
this"), not a ceiling — take the newest stable at or above it. Test stack and its
floors: [docs/testing.md](docs/testing.md).

## Workflow

- **Conventional Commits.** Every commit message follows the spec.
- **Plan before non-trivial changes.** State the plan, then implement.
- **Diagnose from logs, not theory.** When reviewing or troubleshooting _any_
  activity — a failed API call, a deploy, an auth error, a flaky test — pull the
  authoritative log / real error message **first** (audit logs, App Insights /
  OTel traces, the provider's raw response body, `--debug`/verbose output) and
  analyze it rigorously **before** hypothesizing from symptoms. The real error
  settles in one query what guesswork drags out over many. See
  [operations.md](docs/operations.md#diagnose-from-authoritative-sources).
- **Terse replies.** No end-of-turn recaps, no fluff.
- **Ship and fix as needed.** Prefer shipping and iterating over withholding
  until perfect.
- **Definition of done:** build + tests green (and `/readyz` returns 200 for
  deploy tasks).

## Hard rules (imperative — apply everywhere)

These are non-negotiable. Each is detailed in a linked doc; the rule itself lives
here so no agent can miss it.

- **React owns its DOM.** No direct vanilla DOM manipulation of nodes React
  renders (`document.querySelector` + manual mutation). Refs and effects are
  allowed for focus, observers, canvas, third-party widgets, and platform APIs —
  document the escape hatch inline. See [frontend-web](rules/frontend-web.md).
- **UI reads design tokens, not raw values.** Color, type, radius, and spacing
  come from `tokens.json` through Tailwind / shadcn classes — never a hardcoded
  hex (including `bg-[#…]` arbitrary values) or a literal `font-family`. If no
  token fits, add it to `tokens.json` first so it reaches every surface; a
  genuine one-off (optical nudge, `z-[60]` over a third-party widget) is allowed
  but documented inline, like the React escape hatch above. The token-drift gate
  in `./scripts/check.sh` enforces this. See [design-md](docs/design-md.md).
- **Errors are RFC 9457 Problem Details.** Every API error returns
  `application/problem+json`. See [api-designer skill](docs/skill-dependencies.md).
- **Health endpoints are `/livez` + `/readyz`.** Liveness and readiness are
  distinct. See [health-checks](docs/health-checks.md).
- **`VERSION` is the only version source.** Assembly props, `package.json`, and
  `/version` all derive from it. Never hand-edit a derived version. See
  [versioning](docs/versioning.md).
- **New feature flags default OFF.** See [feature-flags](docs/feature-flags.md).
- **Public surfaces pass first-GET-without-JS.** Semantic HTML + JSON-LD +
  OG/Twitter must be in the raw payload. See [seo-discoverability](docs/seo-discoverability.md).
- **HTTP retries on idempotent verbs only.** GET/PUT/DELETE may retry. POST/PATCH
  retry is excluded by default; enabling it requires a commented, justified opt-in
  **and a STOP-and-ask human sign-off** (or a provable idempotency key). See
  [resilience](docs/resilience.md).
- **Client IP/UA retention follows the EFF DNT policy.** The edge log keeps
  raw IP + UA ≤ 10 days, then auto-purged. App telemetry (OTel → App Insights)
  stays geo-only with the IP masked to `0.0.0.0` — raw IP never lands there.
  See [edge](docs/edge.md) + [observability](docs/observability.md).

## Backend: an additive, shared-host topology

A repo runs one **or more** backend components — a public web shell, human HTTP
API(s), an MCP tool server, event/queue processors, jobs — each mapped to a
**host**, and a host can be **shared** by several components. Choose the host(s)
you need; `GOAL-STATE.md` records the topology. Each rule file is self-contained.

### Host decision matrix

| Host | Cold-start | Stateful | Request duration | Cost at idle | Scale shape | Ops burden |
|---|---|---|---|---|---|---|
| [Container Apps](rules/backend-container-apps.md) | tunable (min replicas) | optional | long OK | tunable | bursty or steady; scale-to-zero opt | medium |

Rules of thumb: spiky/event-driven, scale-to-near-zero → Functions; everything else
— steady always-warm APIs (min replicas ≥ 1), long-running work, containers, or
zero-downtime revisions → Container Apps. (App Service is intentionally not a host
option — ACA covers its always-warm case via min replicas.)

**Cost shape before choosing.** Each host rule documents its cost shape — idle
floor, billing meter, free grants, what scales the bill; fetch current numbers
from the Azure pricing pages at decision time (prices move; the shape doesn't).
Evaluate trade-offs **greenfield and per-repo**: another project's existing or
shared infrastructure never tilts the choice — piggybacking on a neighbor's plan
is an operator decision at deploy time, not a kit recommendation.

### Interfaces (composable)

- **Human HTTP API** — the host rule above.
- **[MCP tool server](rules/backend-mcp.md)** — exposes tools to AI agents over
  Streamable HTTP. **Orthogonal to the host**: an ASP.NET Core app on Container
  Apps (kit standard — an OAuth/DCR preference, not an MCP platform limit; the
  rule documents the Functions alternative). Co-host it with a human API, or run
  it alone; if the human API is on Functions, MCP is its own Container Apps
  service.

- **A2A agent server** — agent↔agent interop (Agent Card at
  `/.well-known/agent-card.json`). **Watch-list, not a kit default** — see
  [site-conventions](docs/site-conventions.md) and [watch-list](docs/watch-list.md).
- **Agentic monetization** — machine-priced calls (x402) / delegated agent
  purchases (AP2). Default `none`; see [agentic-commerce](docs/agentic-commerce.md).

A repo can have a human API **and** MCP **and** several hosts — the same way it can
have a web frontend and a mobile app.

## Frontend

- [frontend-web](rules/frontend-web.md) — Astro 6 public shell + Vite React SPA
  app layer, split at the SWA/ACA edge, behind the Cloudflare proxied edge
  ([edge](docs/edge.md)).
- [frontend-mobile](rules/frontend-mobile.md) — React Native, shares the same
  `tokens.json`.

## Cross-cutting concerns

- [design-md](docs/design-md.md) — DESIGN.md standard + token-flow pipeline.
- [feel](docs/feel.md) — motion, loading, empty-state, and error-copy
  conventions + the signature-element gate.
- [seo-discoverability](docs/seo-discoverability.md) — first-GET, OG/Twitter,
  JSON-LD, `X-Robots-Tag`, AEO.
- [site-conventions](docs/site-conventions.md) — well-known files, robots/sitemap,
  favicons, `www`→apex, legal pages.
- [health-checks](docs/health-checks.md) — `/livez` + `/readyz`.
- [versioning](docs/versioning.md) — `VERSION` single source → `/version`.
- [observability](docs/observability.md) — OTel → App Insights, IP→geo, redaction.
- [edge](docs/edge.md) — Cloudflare proxied edge: fronting, verified-bot
  classification, DNT 10-day edge log, protection ladder, CF automation.
- [resilience](docs/resilience.md) — retry/circuit-breaker, idempotency gate.
- [rate-limiting](docs/rate-limiting.md) — app-level limiter, 429 contract.
- [agentic-commerce](docs/agentic-commerce.md) — monetization as an interface:
  x402 machine-priced calls; AP2 on the watch-list.
- [persistence](docs/persistence.md) — data-store menu + access idiom.
- [testing](docs/testing.md) — test stack + version floors (xunit.v3, Vitest, Playwright).
- [auth](docs/auth.md) — Entra ID / External ID, Easy Auth, MSAL.
- [deployment](docs/deployment.md) — azd + Bicep + GitHub Actions tag-push.
- [security](docs/security.md) — Key Vault refs, managed identity, no secrets.
- [feature-flags](docs/feature-flags.md) — Azure App Config + refresh gotcha.
- [operations](docs/operations.md) — design-for-operability + operational to-do list.
- [markdown](docs/markdown.md) — markdownlint config + fenced-code-language rule.
- [scripts](docs/scripts.md) — `./scripts` conventions.
- [commits-workflow](docs/commits-workflow.md) — Conventional Commits, planning.
- [adr](docs/adr/README.md) — lightweight ADR log; every "documented decision"
  gate lands here.
- [skill-dependencies](docs/skill-dependencies.md) — skills this kit delegates to.

## Markdown

`.markdownlint.jsonc` is canonical. Every fenced code block carries a language tag
(use `text` if none fits). ATX headings, short sections. See [markdown](docs/markdown.md).

## Command contract

Canonical commands. Web commands run from the pnpm workspace root.

```text
# .NET
dotnet build
dotnet test
dotnet format
dotnet format --verify-no-changes          # lint/format check (CI)
dotnet run --project src/<app>

# Web (pnpm workspace)
pnpm install
pnpm build
pnpm test
pnpm lint                                   # Biome (.ts/.tsx) + ESLint (.astro)
pnpm format
pnpm dev

# Full verify harness (lint + format + build + tests + markdownlint + view-source)
./scripts/check.sh
```

## Skill dependencies

This kit delegates real work to skills rather than re-teaching it. See
[skill-dependencies](docs/skill-dependencies.md) for the full list and what each
is for (`health-endpoints`, `version-source-of-truth`, `api-designer`,
`markdown`, and others).

## Assumed repo structure

Uniform pnpm-workspace monorepo (every repo looks the same). `.NET` uses NuGet;
pnpm governs only JS packages.

```text
.
├── AGENTS.md                      # this file (canonical)
├── CLAUDE.md                      # pointer (@AGENTS.md import)
├── GEMINI.md                      # pointer
├── VERSION                        # single source of truth for app version
├── SEED_KIT_VERSION               # which seed-kit tag this repo vendored
├── GOAL-STATE.md                  # declarative record of this repo's choices
├── .github/copilot-instructions.md
├── .cursor/rules/00-agents.mdc
├── .markdownlint.jsonc
├── .editorconfig
├── .mcp.json                      # incl. Microsoft Learn docs MCP
├── rules/                         # backend + frontend rule files
├── docs/                          # cross-cutting convention docs
├── scripts/                       # ./scripts/check.sh + helpers
├── packages/
│   └── tokens/                    # DTCG tokens.json (shared web + mobile)
├── apps/
│   ├── web/                       # Astro 6 public shell (+ nested AGENTS.md)
│   ├── app/                       # Vite + React SPA (+ nested AGENTS.md)
│   └── edge/                      # Cloudflare edge Worker (absent when --edge none)
└── src/                           # .NET solution (backend, ServiceDefaults)
```

Nested per-directory `AGENTS.md` files hold only subtree-specific deltas — never
a copy of this content.
