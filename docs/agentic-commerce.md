# Agentic commerce — monetization as an interface

Monetization for machine callers is an **interface axis, same as MCP**: a repo
composes it onto an existing host; it is not a host and it is not a default.
The `GOAL-STATE.md` row records the pick:

| Pick | Means |
|---|---|
| `none` (default) | No machine-priced surface. Most repos. |
| `x402` | Machine-priced HTTP/MCP calls — HTTP 402 + stablecoin settlement. |
| `x402+ap2` | Also accept delegated agent *purchases* (mandates). Watch-list. |

A non-default pick is a documented decision — record the ADR
([docs/adr](adr/README.md)).

## x402 — machine-priced API / MCP calls

[x402](https://www.x402.org/) prices an HTTP request in-band: the server
answers `402 Payment Required` with its payment requirements, the agent pays
(stablecoin, via a facilitator), retries with the payment header, and the
server verifies and settles. HTTP-native and stateless-friendly — a fit for
both kit hosts and for priced MCP tools.

Kit conventions when adopting x402 (delegate execution to the
**`x402-paywall-checklist`** skill — it carries production scar tissue):

- **Receipts are durable.** Settlement receipts survive restarts and replica
  churn — a [persistence](persistence.md)-menu store, never in-memory.
- **Replay defense.** A payment authorizes one request; replays are rejected.
- **Payment + retry is the POST-retry hazard with money attached.** The
  [resilience](resilience.md) hard rule (idempotent-verbs-only) applies
  doubly: a paid call gets an idempotency key before any retry policy touches
  it.
- **Settlement mode and network are pinned.** Testnet vs mainnet is explicit
  config, never inferred; mainnet enablement is its own ADR with guardrails.
- **402s stay machine-legible.** The 402 carries the x402 payment-requirements
  payload; never wrap it in an HTML error page.
- **Priced MCP tools follow the naming hard rule.** Price belongs in the tool
  description (the calling model must see it before invoking); tool/param
  names remain semver-pinned (see [backend-mcp](../rules/backend-mcp.md)).

## AP2 — delegated agent purchases (watch-list)

[AP2](https://agentpaymentsprotocol.info/) (Agent Payments Protocol,
Google-led, builds on A2A) covers the other direction: your product
*accepting* purchases a user's agent makes under delegated authority — Intent
/ Cart / Payment **mandates** expressed as W3C Verifiable Credentials. Status
at last review (2026-06-12): v0.2.0; the **A2A x402 extension** is
production-ready on crypto rails, card rails still maturing. Adopt only with a
paying use case — see [watch-list](watch-list.md) for the revisit trigger.

## Related

- [site-conventions](site-conventions.md) — `/.well-known/agent-card.json`
  when the repo also speaks A2A.
- [rate-limiting](rate-limiting.md) — 402 and 429 are different answers to
  "too much": price the call or throttle it, deliberately.
- [observability](observability.md) — settlement events are operational
  telemetry; payment volume belongs on a dashboard, not just in receipts.
