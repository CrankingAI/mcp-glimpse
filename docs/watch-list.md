# Watch-list

Externally-moving choices the kit deliberately bet on, with the **trigger** that
should make us revisit each — not a fixed cadence. Update `Last reviewed` whenever
an item is re-evaluated, even if the decision stands.

| Item | Last reviewed | Trigger |
|---|---|---|
| MWG (Modern Web Guidance) | 2026-06-01 | Revisit when it exits preview. Baseline "Widely available" remains the authoritative platform-feature bar until then. |
| `@google/design.md` | 2026-06-01 | Revisit on each `0.x` bump / when it leaves alpha. CLI version stays pinned; `tokens.json` is the durable DTCG artifact regardless. |
| `llms.txt` / `llms-full.txt` | 2026-06-01 | Revisit if a major answer engine announces real support. Adoption is currently low — ship it cheaply, do not oversell it. |
| Biome `.astro` support | 2026-06-01 | When it lands, drop the second (ESLint/Prettier) web toolchain and consolidate on Biome for both `.ts/.tsx` and `.astro`. |
| Test-stack majors (`xunit.v3`, Vitest, Playwright, React) | 2026-06-03 | Re-verify the [testing.md](testing.md) floors against the registry on each major bump. Floors are minimums — bump them up, never seed below the current GA major. |
| A2A (Agent2Agent) | 2026-06-12 | Adopt when a real client/partner needs agent↔agent interop. Discovery path `/.well-known/agent-card.json` is already on the [site-conventions](site-conventions.md) checklist; the interface itself is not seeded. |
| AP2 (Agent Payments Protocol) | 2026-06-12 | v0.2.0; A2A x402 extension production-ready on crypto rails, card rails maturing. Revisit when card-rail flows GA or a delegated-purchase use case pays. See [agentic-commerce](agentic-commerce.md). |
| Cloudflare AI Crawl Control / pay-per-crawl | 2026-07-04 | Adopt when charging AI crawlers per-fetch pays (intersects [agentic-commerce](agentic-commerce.md) x402). The edge log ([edge](edge.md)) already answers *who* crawls; this adds *on what terms*. |
