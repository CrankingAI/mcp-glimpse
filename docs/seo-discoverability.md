# SEO / discoverability / AEO

The governing rule is **first-GET-without-JS**: a raw `GET` of any public page, with
JavaScript disabled, must already contain the structured data and semantic markup. This
is a hard rule in [AGENTS.md](../AGENTS.md) and is operationalized as a CI check.

## Why render-on-first-GET is the safe target

| Crawler | Renders JS? |
|---|---|
| Googlebot | yes (deferred render queue) |
| GPTBot (OpenAI) | no |
| ClaudeBot (Anthropic) | no |
| PerplexityBot | no |

Answer engines consume **raw HTML** into RAG context; they do not execute the SPA shell.
Render-on-first-GET is the lowest-common-denominator that serves every crawler, so it is
the target — not "Googlebot will figure it out." The Astro public shell satisfies this by
construction (static HTML); the `/app/*` SPA layer is deliberately out of scope for
indexing (see [X-Robots-Tag](#x-robots-tag-for-app)).

## View-source acceptance test (CI check)

Operationalized as an automated check in the verify harness (`./scripts/check.sh`). It
fetches each public route **with JS disabled** and asserts the raw payload contains:

- a `<script type="application/ld+json">` block,
- `og:` and `twitter:` meta tags,
- exactly one `<h1>`,
- semantic landmarks (`<header>`, `<nav>`, `<main>`, `<footer>`).

```text
# Conceptual shape of the CI assertion (per public route)
curl -s https://mcpglimpse.com/ \
  | assert-contains 'application/ld+json' \
  | assert-contains 'og:image' \
  | assert-contains 'twitter:card' \
  | assert-single '<h1' \
  | assert-landmarks header nav main footer
```

Accessibility and AEO are the same investment: low-JS semantic HTML serves screen
readers, search crawlers, and LLM agents alike.

## Accessibility (WCAG) — checklist + audit tooling

Target **WCAG 2.2 AA**. Most behavior comes for free from the stack — Radix gives
focus management, ARIA wiring, and keyboard semantics in the SPA (see
[frontend-web](../rules/frontend-web.md)); the token pipeline flags sub-4.5:1
contrast pairs at the token layer (see [design-md](design-md.md)). The checklist
below is the part that still needs author attention, plus the tools that verify it.

- **Semantic landmarks + one `<h1>`** — `<header>`/`<nav>`/`<main>`/`<footer>`,
  logical heading order (already asserted by the view-source check above).
- **Keyboard-only operable** — every interactive control reachable and usable
  without a mouse; **visible focus state** on each.
- **Contrast ≥ 4.5:1** for body text (≥ 3:1 for large text / UI components).
- **Text alternatives** — meaningful `alt` on images; captions/transcripts for
  audio and video; `aria-label` only where visible text cannot carry the meaning.
- **Form semantics** — every input has a programmatic `<label>`; typed inputs
  (`email`, `tel`, `date`) for correct mobile keyboards and validation.

Audit tooling (run in CI where cheap, manually otherwise):

- **[axe](https://www.deque.com/axe/)** / **Lighthouse** (Chrome DevTools) —
  automated a11y + performance passes.
- **[WAVE](https://wave.webaim.org/)** — visual a11y annotations.
- **[W3C HTML validator](https://validator.w3.org/)** and
  **[CSS validator](https://jigsaw.w3.org/css-validator/)** — standards conformance.
- **[Schema.org validator](https://validator.schema.org/)** /
  **[Google Rich Results test](https://search.google.com/test/rich-results)** —
  validate the JSON-LD emitted above.

## JSON-LD

Inject JSON-LD into the `<head>` at build time. Two tiers, with different intent.

### Rich-result / structured-data drivers

These are the schemas search and answer engines actually map and may surface:

- `Organization`
- `WebSite`
- `BreadcrumbList`
- `Article` / `TechArticle`
- `Product`

### AEO machine-legibility (NOT rich-result drivers)

- `FAQPage`
- `SoftwareApplication`

These are emitted for **AEO machine-legibility** — helping answer engines parse the page
— **not** as Google rich-result drivers. Google **dropped FAQ rich results for all sites
on 2026-05-07**, so do not justify `FAQPage` by rich snippets. Ship it because it makes
the page legible to LLM crawlers, and frame it that way in reviews.

### Match the schema to the page's shape (execution-validated)

Proven live on a shipped content corpus (fleet, [backlog.md](../backlog.md) §14 —
30 entity pages + 435 combinatorial pages). Pick `@type` by what the page *is*:

- **Question-shaped page → `QAPage`.** A page whose title is literally a
  question ("Is MIT compatible with GPL-3.0-only?") carries a `QAPage` whose
  accepted answer is the verdict + reason.
- **Entity page → `TechArticle` + a `FAQPage`.** The `FAQPage` is **derived from
  the page's own structured data, never hand-written** — so the answers can't
  drift from the page.
- **Reference surface → `Dataset` / `DefinedTermSet`.**
- Emit all of it through **one `jsonLd` slot on the base layout** — one seam,
  every page, so a route can't forget it.

### Combinatorial pages: canonical ordering only

For pairwise/combinatorial content (A-vs-B), generate **only the canonical
ordering** (e.g. `a < b` ordinal), never the reverse, and derive **every
internal link from the same slug function the routes use**. A shipped matrix
verified 870/870 links resolve with zero 404s because links and routes shared
one slug source — the generated-artifact discipline ([testing](testing.md))
applied to URLs.

### Build-output guard tests

A tiny test suite that reads the built `dist/` and asserts **exact page counts,
presence of each JSON-LD `@type`, and the `llms.txt`/corpus markers**. It catches
template regressions a type-checker cannot (a layout change that drops the
`jsonLd` slot compiles fine and ships broken). Runs in the `pnpm -r test` gate —
after the build, since it reads build output ([check.sh](../scripts/check.sh)).

### JSON-LD validation in CI

Add a **JSON-LD validation step** to CI: parse each emitted block and assert it is valid
JSON-LD against the declared `@type`. A malformed block silently de-legibilizes the page,
so this is a gate, not a warning.

## OpenGraph and Twitter cards

Emit **both** the OG tag set and the Twitter `summary_large_image` set (they are separate
namespaces — do not assume one falls back to the other).

- `og:image` must be an **absolute URL**, **1200×630**.
- Always include `og:image:alt`.

```html
<meta property="og:title" content="…" />
<meta property="og:description" content="…" />
<meta property="og:image" content="https://mcpglimpse.com/og/default.png" />
<meta property="og:image:alt" content="…" />
<meta name="twitter:card" content="summary_large_image" />
<meta name="twitter:image" content="https://mcpglimpse.com/og/default.png" />
```

### Static OG is the default

Static OG images are the default — a checked-in 1200×630 card per surface (or one
site-wide card). Use `astro-seo` or a small custom `<SEO>` component in the base layout.

### Dynamic OG is opt-in

Dynamic per-page cards via **Satori + resvg** (`@vercel/og`-style) are **opt-in** behind
a product decision (see [site-conventions](site-conventions.md)). Satori is
**flexbox-only** — no grid, no float; author card layouts accordingly. Cards are fed
token colors/typography from `tokens.json` so they auto-match the design system (see
[design-md](design-md.md)).

Validate cards with LinkedIn Post Inspector, Facebook Sharing Debugger, opengraph.xyz.

## X-Robots-Tag for /app/*

The `/app/*` SPA layer is not indexable. Set the HTTP response header:

```text
X-Robots-Tag: noindex,nofollow
```

**Do NOT also `Disallow: /app/*` in `robots.txt`.** A disallowed path is never fetched,
so the crawler never sees the `noindex` directive and the URL can still appear in results
without a snippet. Pick one mechanism — the header — and let crawlers fetch the path to
read it. `robots.txt` and the sitemap live in [site-conventions](site-conventions.md).

## llms.txt — watch-list, ship cheaply

`llms.txt` (and `llms-full.txt`) is a **watch-list item**: adoption by answer engines is
currently low. Ship it if cheap, do not oversell it, and do not build expensive tooling
around it. Revisit if a major answer engine announces real support. See
[watch-list](watch-list.md) and the file conventions in
[site-conventions](site-conventions.md).

**When you do ship it, generate it from the same structured data as the pages** —
`llms.txt` (a linked index) and `llms-full.txt` (the whole corpus in one fetch)
as static endpoints built from the page data, never hand-maintained, so the
corpus can't drift from the HTML. This is the generated-artifact discipline
([testing](testing.md)) again, and it pairs with the edge Worker already
watching those routes ([edge](edge.md)).
