# Skill dependencies

The kit does real work by **delegating to skills** rather than re-documenting their
behavior. A seeded repo depends on the skills below — keep this list current so
adopters know what to install. Where a convention doc states a contract, the
matching skill is the executor.

## Existing skills the kit delegates to

| Skill | Purpose (one line) |
|---|---|
| `swa-fullstack` *(archived)* | Was a **SWA + React SPA + .NET Functions** scaffolder only — never an Astro-shell or ACA/MCP scaffolder, and now archived/unavailable. Until a replacement lands, scaffold each slot from its `rules/` file (e.g. [frontend-web.md](../rules/frontend-web.md), the chosen `backend-*.md`). |
| `health-endpoints` | Adds `/livez` (liveness) + `/readyz` (readiness) endpoints. Contract in [health-checks.md](health-checks.md). |
| `version-source-of-truth` | Wires the `VERSION` file as the single source for assembly/package versions and the `/version` endpoint. Contract in [versioning.md](versioning.md). |
| `tag-version-bits-alignment` | Verifies a deployed build's bits match the `v*` git tag it claims to be. |
| `api-designer` | Designs idiomatic .NET 10 HTTP APIs: OpenAPI-first contracts, RFC 9457 Problem Details, status codes, resource naming, versioning. |
| `scripts-convention` | Enforces `./scripts/` conventions: `-h`/`--help`, fail-fast, coherent naming, macOS bash 3.2 compatibility. Contract in [scripts.md](scripts.md). |
| `markdown` | Markdown editing, linting, and markdownlint-fixing against the canonical `.markdownlint.jsonc`. Contract in [markdown.md](markdown.md). |
| `privacy-policy-drafter` | Drafts accurate, minimal privacy policies; pairs with cookie-consent + RUM wiring. Referenced from [observability.md](observability.md). |
| `design-consultation` | Produces `DESIGN.md` as the project's design source of truth (aesthetic, type, color, layout, tokens). Contract in [design-md.md](design-md.md). |
| `aca-deploy-verification` | Verifies an Azure Container Apps deploy landed: revision state, deployed config, ingress posture, App Insights deploy-window queries. |
| `zero-downtime-aca-contract` | The zero-downtime ACA revision contract (readiness-gated traffic shift, no in-place mutation). |
| `setup-deploy` | Sets up the azd + Bicep + GitHub Actions tag-push deploy path. Contract in [deployment.md](deployment.md). |
| `x402-paywall-checklist` | Correctness traps for x402 micropayment paywalls in .NET (mainnet guardrails, receipt durability, replay defense, settlement pinning). Referenced from [agentic-commerce.md](agentic-commerce.md). |

## New kit skills

| Skill | Purpose (one line) |
|---|---|
| `seed-sync` | Agent-driven vendoring + 3-way re-seed/reconcile of subsections against `DevPartners/meta-agent-md@<tag>`; merges local edits vs. upstream changes and surfaces genuine conflicts for human review. |
| `operational-readiness` | Audits the per-environment operational to-do list (backups/PITR, rotation cadence, alert wiring, cost guardrails, scale min/max, residency, rate-limit visibility). See [operations.md](operations.md). |
