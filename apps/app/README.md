# apps/app — app layer (Vite + React SPA)

Placeholder. The Vite + React SPA lives here, served under `/app/*` and marked
`noindex`. This is the heavy, client-contained surface (TanStack Query + Zustand +
React Hook Form + Zod + React Router 7).

**Scaffold this from [`rules/frontend-web.md`](../../rules/frontend-web.md)**
(the SPA app-layer section). **Do not run `swa-fullstack` here:** it is archived,
and its output (a React SPA + .NET Functions in a root-level `app/`/`api/`/`shared/`
layout) collides with this monorepo's `apps/`, `src/`, and `infra/`. Replace this
placeholder before the slot goes live — an unscaffolded slot must never ship.

## What this SPA must provide

- Imports `@CrankingAI/tokens` — shares the same `tokens.json` / Tailwind v4 design
  system as `apps/web`.
- `noindex`: `X-Robots-Tag: noindex, nofollow` on `/app/*` (and not also disallowed
  in `robots.txt`, or the header is never seen).
- Client-side routing needs a **fallback rewrite** so deep links resolve to the SPA
  entry: `navigationFallback` on Azure SWA; a catch-all → `index.html` on ACA.
- Lint/typecheck/build/format scripts in its `package.json` so the root `pnpm -r`
  fan-out reaches it.
