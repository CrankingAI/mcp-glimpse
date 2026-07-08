# apps/web — `www.mcpglimpse.com` (static Astro)

The AEO-tuned marketing + Learn site for mcp-glimpse. **Fully static** (Astro,
`output: 'static'`) — no SSR, no client framework — so it satisfies the
first-GET-without-JS rule for free and deploys to Azure Static Web Apps.

## Develop

```sh
npm install
npm run dev      # local dev server
npm run build    # -> dist/ (static)
npm run preview  # serve the built dist/
```

## How it's wired

- **Design system:** "Paper & Proof" (`packages/tokens/DESIGN.md`) applied as
  global CSS custom properties in `src/layouts/BaseLayout.astro` — warm paper
  light default, rationed gate-green accent, Instrument Serif / Instrument Sans /
  JetBrains Mono via Google Fonts `<link>`. A `prefers-color-scheme: dark` block
  maps onto the "Bench" dark tokens.
- **Content source of truth:** the Learn library is a content collection
  (`src/content/learn/*.md`, schema in `src/content.config.ts`). Each article's
  frontmatter carries the question (`title`), the direct `answer`, and the 2-3
  on-page `faqs` the FAQPage JSON-LD is derived from. Site constants live in
  `src/data/site.ts`.
- **No drift:** `sitemap.xml`, `feed.xml`, `llms.txt` and `llms-full.txt` are
  Astro endpoints (`src/pages/*.ts`) generated from that same collection + data
  module, so they can't disagree with the pages.
- **JSON-LD:** one reusable `src/components/JsonLd.astro`, injected into `<head>`
  by `BaseLayout` from a `jsonld` prop. Homepage → WebSite + SoftwareApplication;
  Learn articles → TechArticle + FAQPage + BreadcrumbList; card → CreativeWork.
- **The App demo:** the self-contained interactive App is copied to
  `public/app-demo.html` and embedded on the homepage via `<iframe>` (`?demo=1`).

## Routes

`/` · `/learn` + 9 `/learn/<slug>` articles · `/c/[id]` (static template + the
`/c/example` "Agent Facts" card) · `/privacy` · `/security` · `/404`. Machine
surfaces: `/robots.txt`, `/sitemap.xml`, `/feed.xml`, `/llms.txt`,
`/llms-full.txt`, `/.well-known/security.txt`, `/og/og-default.png` (1200×630).

## Regenerating the OG card

`public/og/og-default.png` is hand-rendered with ImageMagick (see the build
report). Re-run that command if the wordmark or tagline changes.

## Deploy (Azure SWA)

`staticwebapp.config.json` ships in `public/` (copied verbatim to `dist/`). Point
the SWA `app_location` at `apps/web` with output `dist` and no API build.
