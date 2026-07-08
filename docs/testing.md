# Testing

The test stack, named explicitly so generated code does not regress to a stale
major. Cross-cutting: applies to whichever backend you picked plus both web
layers. The package versions below are a **minimum floor — use the latest stable
at seed time, not below these** (the standing directive: verify from NuGet / npm,
never from memory).

## Why this doc is pinned

"Write idiomatic tests" reliably produces the major a tool was most famous for —
which for xUnit is the legacy `xunit` 2.x line, even though `xunit.v3` is the
current GA framework (different package id, different runner). The same trap waits
in any package with a recent major bump. Naming the major is the fix.

## .NET

| Concern | Choice | Floor |
|---|---|---|
| Unit + integration framework | **`xunit.v3`** (NOT the legacy `xunit` 2.x package) | `xunit.v3` 3.* |
| Test runner | **Microsoft Testing Platform** (xunit.v3's default); add `xunit.runner.visualstudio` for VSTest / `dotnet test` integration | latest stable |
| Test SDK | `Microsoft.NET.Test.Sdk` | latest stable |
| Assertions | xUnit built-ins (add FluentAssertions only if a repo already leans on it) | — |
| HTTP / API integration | **`WebApplicationFactory<T>`** (`Microsoft.AspNetCore.Mvc.Testing`) — real pipeline, in-memory | latest stable |
| Relational data | **Testcontainers** (real engine, ephemeral) — SQL / Postgres. See [persistence](persistence.md). The Cosmos emulator is heavy/flaky; isolate it. | latest stable |

```xml
<!-- Floor — take the newest stable at or above each at seed time. -->
<PackageReference Include="xunit.v3" Version="3.*" />
<PackageReference Include="xunit.runner.visualstudio" Version="*" />
<PackageReference Include="Microsoft.NET.Test.Sdk" Version="*" />
<PackageReference Include="Microsoft.AspNetCore.Mvc.Testing" Version="*" />
```

- A migration from an existing `xunit` 2.x project is a package-id change
  (`xunit` → `xunit.v3`) plus a runner switch — not a drop-in upgrade. Do it
  deliberately; do not seed new repos on 2.x.

## Web

| Concern | Choice | Floor |
|---|---|---|
| Unit / component | **Vitest** + **Testing Library** | latest stable |
| End-to-end / browser | **Playwright** | latest stable |

- Component tests live with the SPA (`apps/app`); the public Astro shell's
  contract is the first-GET view-source assertion in the verify harness, not a
  component test.

## Generated artifacts + a drift gate (never two implementations)

When the same domain data or logic is needed on **both the .NET and the JS
side** of the monorepo, the authoritative (.NET, or whichever owns the logic)
source **emits a committed data artifact** that the other side consumes, guarded
by a **CI drift test** (regenerate + compare; fail if stale). **Never port the
logic to a second language** — two implementations of a rule that must stay in
lockstep drift silently, and the drift is invisible until it burns someone.

The kit already embodies this in three places — it is one pattern, now named:

- `packages/tokens/tokens.json` → `theme.css` (via `packages/tokens/build.mjs`)
  — the design-token pipeline.
- The **MCP contract snapshot** (`mcp-contract.json`) — freeze the
  tool/prompt/resource surface, fail CI on drift (see
  [backend-mcp](../rules/backend-mcp.md)).
- Any shared **domain data** a repo adds (a compatibility rule set, a pricing
  table, a validation matrix): the .NET engine emits the JSON; the Astro/SPA
  build renders from it; a drift test regenerates and diffs.

The instinct to "just reimplement it in TypeScript for the web build" is the
trap this rule forecloses. Same mechanism as the token-drift and
contract-snapshot gates — different artifact, no new machinery.

> **A drift gate only counts if CI runs it.** Execution-validated the hard way
> (fleet, [backlog.md](../backlog.md) §14): a repo's drift test was green
> locally but the deploy pipeline never ran `dotnet test`, so a stale-data
> deploy would have shipped green. **Every gate suite rides the deploy
> pipeline** — the tag-push workflow runs the same `dotnet test` / `pnpm -r test`
> / build-output guards that `check.sh` runs, not a lighter subset. See
> [deployment](deployment.md).

## Policy (all stacks)

- **Coverage is advisory** — no brittle percentage floor that blocks merges.
- **Tests are required for new logic.** New behavior ships with a test.
- **Definition of done** = build + tests green (and `/readyz` 200 for deploy
  tasks). This mirrors the workflow rule in [AGENTS.md](../AGENTS.md).
- Both `dotnet test` and `pnpm test` are part of the [`scripts/check.sh`](../scripts/check.sh)
  verify harness and the CI build + test gate.
