# apps/web — public shell (Astro 6)

Placeholder slot. The Astro 6 + Tailwind v4 public shell lives here, with any
interactive bits as **React islands hydrated through Astro `client:*` directives**
(not a React app — keep the shell distinct from the `apps/app` SPA). This is the
indexable, AEO-legible surface (`/`, `/blog/*`, `/docs/*`) that must satisfy the
first-GET-without-JS principle.

**Scaffold this from [`rules/frontend-web.md`](../../rules/frontend-web.md)** — the
Astro 6 + Tailwind v4 + tokens wiring is a handful of small files and is fine to
hand-build. **Do not run `swa-fullstack` here:** it does not emit an Astro shell
(it produces a React SPA + .NET Functions in a different layout), and a
client-rendered SPA would violate the first-GET-without-JS hard rule. Replace this
placeholder before the slot goes live — an unscaffolded slot must never ship.

## What this shell must provide

- Imports `@EffAz/tokens` — Tailwind v4 `@theme` is derived from the shared
  `tokens.json`, so this shell and `apps/app` share one design system and cannot
  drift.
- Static-by-construction output for the public surface.
- Lint/typecheck/build/format scripts in its `package.json` so the root
  `pnpm -r` fan-out reaches it.
