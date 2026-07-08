# Frontend — Web

Self-contained. Deleting any sibling rule leaves no broken links here.

## Governing principle

The bot must see structured data and semantic HTML on the **first GET, without
executing JavaScript**. Answer engines (GPTBot, ClaudeBot, PerplexityBot) and
social crawlers consume raw HTML, JSON-LD, and OpenGraph; they do not run the SPA.
Googlebot renders JS, but render-on-first-GET is the safe lowest common
denominator. This is the spine of everything below. See
[seo-discoverability.md](../docs/seo-discoverability.md) and the view-source
acceptance test (a CI gate).

## Architecture — decoupled hybrid shell

Two layers, one design system, split at the SWA edge.

| Layer | Routes | Builder | First-GET met by |
|---|---|---|---|
| Public shell (indexable) | `/`, `/blog/*`, `/docs/*`, marketing | Astro 6 + Tailwind v4 + React islands | Static semantic HTML by construction |
| App layer (`noindex`) | `/app/*`, `/dashboard/*` | Vite + React SPA | Client-contained; `X-Robots-Tag: noindex, nofollow` |

The public shell is static by construction, so it passes the first-GET test for
free. The app layer is the whole-page-is-the-app surface; it is explicitly not
indexed.

### Builder choice

- **Prefer Astro** for the public shell. It is the default a seeded repo starts
  from.
- **Next.js requires a documented decision** — not "never", but it must be
  justified in writing (typically only when a product is *primarily* the app with
  marketing as an afterthought, which is not the usual case). Record the rationale
  as an ADR ([docs/adr](../docs/adr/README.md)) before reaching for it.

### Edge split — `staticwebapp.config.json`

Route rules at the Azure SWA CDN edge send public paths to the Astro build and
`/app/*` to the SPA. The SPA does its own client-side routing, so it needs a
fallback rewrite or deep links 404:

- **SWA:** `navigationFallback` rewrites unknown `/app/*` paths to the SPA
  `index.html`.
- **ACA (containerized):** a catch-all route → `index.html`.

```json
{
  "routes": [
    { "route": "/app/*", "headers": { "X-Robots-Tag": "noindex, nofollow" } }
  ],
  "navigationFallback": {
    "rewrite": "/app/index.html",
    "exclude": ["/", "/blog/*", "/docs/*", "/*.{css,js,png,svg,webp,ico,xml,txt}"]
  }
}
```

The `noindex` header is the index-control boundary. Do not also `Disallow`
`/app/*` in `robots.txt` — if the crawler is blocked it never sees the header.

**Place `staticwebapp.config.json` in the published output dir, not the repo
root.** For Astro, put it in `apps/web/public/` so the build copies it verbatim
to `dist/`. The SWA deploy reads it from `app_location` (the built output); a copy
at the repo root or `apps/web/` root is never seen, and the route /
`navigationFallback` rules above silently don't apply — no error, just missing
edge behavior.

**Skipping the SWA build for a prebuilt managed API requires a declared
runtime.** If the deploy sets `skip_api_build: true`, add
`"platform": { "apiRuntime": "node:22" }` to `staticwebapp.config.json` —
skipping the build bypasses Oryx language auto-detection, so without it the deploy
fails with "Function language info isn't provided." (Linked .NET backends with
`api_location: ""` don't hit this — see `backend-functions`.)

### Where a new page goes (decide this first)

Before building any new page or route, classify it. This single question prevents
the "single SPA, no router — hash view vs add-a-router vs static HTML?" dilemma; in
this architecture that dilemma never arises.

- **Public / content** (marketing, `Learn`, docs, blog, pricing, legal) → an
  **Astro page in the public shell** (e.g. `apps/web/src/pages/learn.astro`).
  Astro's file-based routing means there is **no router decision and no new
  dependency** — it is one file, served as static semantic HTML with JSON-LD and a
  sitemap entry, indexable and answer-engine-citable on the first GET.
- **Authenticated / interactive app UI** → a **React Router 7 route under
  `/app/*`** in the SPA. The router already ships with the app (see
  [SPA stack](#spa-stack-app)); adding a route is conventional, not a new choice.

**Never put indexable content behind a client-rendered hash or SPA route**
(`#learn`, a `/app/*` view). It fails the first-GET test — crawlers and answer
engines see nothing — and the verify harness's view-source assertion will flag it.
A real `/learn` static path also avoids the 404/405 that clickable links to
SPA-only paths produce.

## Component layer

- **shadcn/ui on the unified `radix-ui` package** (the single-package form shipped
  in the Feb-2026 shadcn change). Used via React islands in Astro and directly in
  the SPA. Radix gives WCAG 2.2+ behavior — focus management, ARIA wiring, keyboard
  semantics — for free; accessibility and AEO are the same investment.
- **Base UI** is the supported alternative primitive layer when a component is not
  well served by radix-ui.
- Components are styled by the design tokens — see
  [design-md.md](../docs/design-md.md).

### Binding shadcn to the token namespace

`shadcn init` writes semantic vars to `:root` (`--primary`, `--background`,
`--border`, `--ring`, `--radius`, …) with hardcoded values, plus an
`@theme inline` block that maps utilities onto them (`--color-primary:
var(--primary)`). The token build emits the **Paper & Proof semantic layer**
(`--color-background`, `--color-primary`, `--color-ring`, … — see
`packages/tokens/DESIGN.md`), so every role shadcn references exists as a
token. Bridge the two by pointing shadcn's `:root` values at the token vars —
replace the generated literals, never keep them:

```css
@import "tailwindcss";
@import "@CrankingAI/tokens/theme.css";   /* @theme + [data-theme="dark"] override */

:root {
  --background:  var(--color-background);
  --foreground:  var(--color-foreground);
  --primary:     var(--color-primary);            /* ink buttons — not green */
  --primary-foreground: var(--color-primary-foreground);
  --muted:       var(--color-muted);
  --border:      var(--color-border);
  --input:       var(--color-border-strong);
  --ring:        var(--color-ring);               /* focus = gate green */
  --destructive: var(--color-danger);
  --radius:      var(--radius-md);
}
```

Dark mode: the generated `theme.css` already carries a `[data-theme="dark"]`
override block re-deriving the same variable names, so this seam is
theme-agnostic — stamp `data-theme="dark"` on `<html>` (and add
`@custom-variant dark (&:where([data-theme="dark"], [data-theme="dark"] *));`
if `dark:` utilities are wanted). This `:root` block is the single seam between
the two namespaces — a token rename is one line here, not a component sweep.
Fonts need no binding: the build emits `--font-serif` / `--font-sans` /
`--font-mono`, the names shadcn and Tailwind both use. The token-drift gate
fails the build on any literal that slips back in.

## CSP & client scripts (Astro shell)

A strict `script-src 'self'` Content-Security-Policy is the secure default for the
public shell. The kit does not yet mandate one (see [security.md](../docs/security.md)),
but **build as if it does** — under `'self'`, inline script content is blocked, and the
failure is **silent in local dev**: it only surfaces in the deployed browser console.

- **Allowed under `'self'`:** Astro's default processed `<script>` — it is hoisted and
  bundled to a same-origin file under `/_astro/*.js` — and any script you author in
  `public/*.js` loaded via `<script src="/path.js">`. Prefer these.
- **Blocked under `'self'`:** `<script is:inline>`, `<script define:vars={…}>` (it
  forces the script inline), and inline event-handler attributes (`onclick="…"`). Move
  that logic into a same-origin external script. Even a copy-to-clipboard button dies in
  production if written inline.
- A genuinely required inline script means the CSP must carry a per-response **nonce**
  (or hash) for it — a deliberate, documented exception, never the default.

## Platform-feature bar

- **Baseline "Widely available"** (web.dev) is the authoritative bar. Reach for a
  newer feature only when explicitly called for, and adapt every web-platform
  pattern to React/JSX idiom.
- **Modern Web Guidance (MWG) is watch-list only**, not the bar — revisit when it
  exits preview. See [watch-list.md](../docs/watch-list.md).

## React idioms (hard rules)

- **React 19** (current major) — use its idioms: `ref` as a prop (no
  `forwardRef`), the `use()` hook, Actions / `useActionState`. Do not seed 18-era
  patterns. Same major across web and mobile.
- Functional components, hooks, and refs only.
- **No vanilla DOM that React owns** — no `document.querySelector` or manual node
  mutation of React-rendered nodes.
- Refs and effects **are** the right tool for: focus management, observers
  (`IntersectionObserver`, `ResizeObserver`), canvas, third-party widgets, and
  platform APIs. These imperative escape hatches are allowed; **document each one
  inline** at the call site explaining why React cannot own it. This matches the
  mobile rule in [frontend-mobile.md](frontend-mobile.md).

## Token pipeline

- **DTCG `tokens.json` is the canonical source of truth**, shared by both layers
  so the shell and SPA cannot drift.
- It maps to the Tailwind v4 `@theme` block (a flat CSS-variable-namespace
  mapping). The same `tokens.json` feeds the React Native theme — see
  [frontend-mobile.md](frontend-mobile.md).
- Full pipeline, producer, and version-pinning: [design-md.md](../docs/design-md.md).

## SPA stack (`/app/*`)

All client-side; identical on SWA and ACA.

- **TanStack Query** — server-state / data fetching.
- **Zustand** — client state.
- **React Hook Form + Zod** — forms and validation.
- **React Router 7** (framework mode) — client routing.
- **Vitest + Testing Library** (component) and **Playwright** (E2E) — testing.
  Use the current major of each; full stack and version floors:
  [testing.md](../docs/testing.md).

### Auth / session boundary

The public Astro shell stays script-free and anonymous. Auth and session live in
the app layer behind the `/app/*` boundary. Default mechanism is platform Easy
Auth; MSAL/JWT is the path when you outgrow Easy Auth or need granular scopes. The
auth choice is confirmed per repo during seeding, not silently baked. See the
auth doc for the workforce (Entra ID) vs consumer (Entra External ID) split.

### Performance

SPA performance is tracked **operationally via client RUM**, scoped to the
`/app/*` layer only — never the public shell (which stays script-free) — and wired
to cookie consent. It is **not a CI gate**. See
[observability.md](../docs/observability.md) and
[operations.md](../docs/operations.md).
