# @CrankingAI/tokens

Shared design tokens for the workspace. **`tokens.json` (W3C DTCG format) is the
canonical source of truth / contract.** Both apps import this package so the public
Astro shell and the Vite React SPA cannot drift.

## Contract

- `tokens.json` — canonical DTCG tokens (color, font, spacing). Edit here only.
- `theme.css` — derived Tailwind v4 `@theme` block (a build artifact).

Consumers import `@CrankingAI/tokens/theme.css` (Tailwind v4) or read
`@CrankingAI/tokens/tokens.json` directly (e.g. an OG-image generator or RN theme).

## How the Tailwind v4 preset is derived

Tailwind v4 is configured in CSS via `@theme`. The DTCG → Tailwind mapping is a flat
CSS-variable-namespace mapping: each token path becomes a `--<namespace>-<name>`
variable. For example:

```text
color.brand.primary  -> --color-brand-primary: #2563eb;
font.sans            -> --font-sans: Inter, system-ui, sans-serif;
spacing.gap          -> --spacing-gap: 12px;
```

(Reserved leaf keys — including the shipped `spacing.sm` / `spacing.md` — are
auto-remapped so they cannot shadow a built-in scale; see below.)

An app imports the generated block, then uses the variables through Tailwind
utilities (`bg-brand-primary`, `font-sans`, `p-gap`):

```css
@import "tailwindcss";
@import "@CrankingAI/tokens/theme.css";
```

## Producing the tokens

`tokens.json` is authored by hand or by a token producer (the `design-consultation`
skill drives DESIGN.md authoring and lint). The DTCG format is the durable layer;
the producer is replaceable.

`theme.css` is **generated** from `tokens.json` by the zero-dependency
`build.mjs` (no Style Dictionary, no project). It is a build artifact —
**gitignored, never committed**. Regenerate it with:

```bash
pnpm --filter @CrankingAI/tokens build
```

### Reserved-key auto-remap

Tailwind v4's `@theme` sizing scale uses t-shirt leaf keys (`xs`, `sm`, `md`,
`lg`, `xl`, `2xl`…`9xl`, plus `px`). A token whose **leaf** key is one of these
would shadow a built-in sizing variable (e.g. `spacing.md` → `--spacing-md`). To
prevent that, `build.mjs` **auto-remaps** exactly those keys under a `space`
segment and logs each remap (utility keywords like `full` / `auto` / `screen` are
not `@theme` leaves, so they are left as-is):

```text
spacing.md  ->  --spacing-space-md   (utility: p-space-md)
```

This is automatic and logged — you do not need to rename tokens, but be aware the
emitted utility carries the `space-` segment for reserved keys.
