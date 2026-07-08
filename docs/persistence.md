# Persistence

**No single baked default.** Pick the store per scenario from the menu below; the
access idiom follows the choice. Do not reach for one store reflexively — match the
shape of the data and the workload.

## The menu

| Store | Use it for | Access idiom |
|---|---|---|
| **Azure SQL DB** | relational / line-of-business | **EF Core** |
| **Postgres Flexible + `pgvector`** | relational + AI / RAG (vector search) | **EF Core** |
| **Cosmos DB serverless** | NoSQL, scale-to-near-zero | **native Cosmos SDK** |
| **Storage blobs / tables** | cheap / simple key-value or files | **Storage SDK** |

EF Core for the relational stores; the **native Cosmos SDK** for Cosmos (do not put
EF Core in front of it); the **Storage SDK** for blobs/tables.

## Cost shape (surface before picking)

The menu above is capability-first, but cost is the human's first real question —
surface each store's cost *shape* alongside it, with current numbers fetched from
the Azure pricing pages at decision time (approximate, region-varying; last
reviewed 2026-06-12):

| Store | Idle / floor | Meter | The lever that scales the bill |
|---|---|---|---|
| Azure SQL DB | bills while provisioned (serverless tier can auto-pause) | vCore/DTU + storage | provisioned compute size; always-on tiers |
| Postgres Flexible | bills while running (stoppable ≤ 7 days; no auto-pause) | compute per hour + storage | compute SKU; HA doubles compute |
| Cosmos DB serverless | ~$0 idle | per-RU consumed + storage | request volume; provisioned-throughput tiers |
| Storage blobs / tables | ~$0 idle | per-GB + per-operation | egress + transaction volume at scale |

## Locks (where relevant)

- **Passwordless / managed-identity DB auth.** No connection-string secret —
  `DefaultAzureCredential` + an Entra-authenticated database principal. See
  [security](security.md).
- **Migrations run as a CI/CD step, never at app startup.** Schema changes are a
  pipeline stage (e.g. `dotnet ef database update` / a migration bundle) gated before
  deploy — never applied by the app process on boot. See [deployment](deployment.md).

## Local dev and testing

- **SQL / Postgres → Testcontainers.** Clean, ephemeral, real engine in CI and
  locally.
- **Cosmos → the emulator is heavy / flaky.** Prefer an **ephemeral serverless Cosmos
  DB** for tests, or document the emulator flake if you must use it. Do not gate CI on
  the Cosmos emulator without a documented fallback.

## What is NOT decided here

Backup / PITR, data residency, and ongoing cost guardrails (budgets, alerts) are
**operational** concerns handled via the per-environment operational to-do list,
not baked into this menu — the [cost shape](#cost-shape-surface-before-picking)
above is the seed-time view. See [operations](operations.md).

## Related

- [security](security.md) — passwordless DB auth via managed identity.
- [deployment](deployment.md) — migrations as a CI/CD step.
- [operations](operations.md) — backup / PITR / residency / cost on the to-do list.
