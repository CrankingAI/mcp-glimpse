# DESIGN.md and design tokens

The **DTCG `tokens.json` is the canonical source of truth** for the design system —
the contract every consumer reads. It is a W3C Design Tokens Community Group document
(stable `2025.10` format). The bet is on **DTCG**, not on any one authoring tool.

`DESIGN.md` is the human-authored design brief (aesthetic, typography, color, spacing,
motion). `@google/design.md` is **one producer** that compiles `DESIGN.md` into
`tokens.json` and a Tailwind v4 `@theme` block. It is not the source of truth — the
committed `tokens.json` is.

## What is committed

```text
packages/tokens/
├── DESIGN.md            # design brief — ships FILLED: "Paper & Proof", the fleet default
├── tokens.json          # DTCG 2025.10 — THE canonical artifact (commit this)
└── build.mjs            # zero-dep transform -> theme.css (@theme + dark override)
```

`tokens.json` is the **durable artifact**. Commit it. Every consumer (web build, OG
image generator, React Native theme) reads it. If the producer's authoring format ever
shifts, the committed `tokens.json` still stands on its own.

**The seed is not a stub.** It ships the complete fleet-default system —
**Paper & Proof** (warm paper + ink neutrals, the rationed gate-green accent,
a full semantic layer wired to shadcn's variable roles, light + dark themes,
radii/shadow, and the `feel.md` motion tokens: `duration.*` + `ease.*`). The
`dark` token group re-derives the same semantic names and is emitted as a
`[data-theme="dark"]` override block. Aliases (`{color.green.600}`) are
resolved by the build with cycle detection.

## Authoring DESIGN.md

The shipped `DESIGN.md` is the fleet default — a per-repo identity is an
**override, recorded in its Decisions Log**, not a silent drift. Use the
**design-consultation** skill to author or revise `DESIGN.md`. It researches the
product, proposes a complete system, and writes `DESIGN.md` as the project's design
brief. Do not hand-roll a design system doc when the skill does this.

## @google/design.md — one producer, pinned, experimental

`@google/design.md` is labelled **experimental / alpha — may be replaced**. Treat it as
a replaceable compiler, never as the contract.

- **Pin the CLI version.** Never run it floating; a pinned version keeps output stable
  across machines and CI. Bump deliberately, re-review the diff in `tokens.json`.
- Tracked on the watch-list — revisit on each `0.x` bump or when it leaves alpha. See
  [watch-list](watch-list.md).

### Commands

```text
# Tailwind v4 @theme block (CSS variable namespace)
npx @google/design.md export --format css-tailwind DESIGN.md > apps/web/src/styles/theme.css

# DTCG tokens.json — the canonical artifact (commit this)
npx @google/design.md export --format dtcg DESIGN.md > packages/tokens/tokens.json

# Lint as a CI gate
npx @google/design.md lint DESIGN.md
```

The **`lint` command is a CI gate.** It fails the build on broken token references and
flags sub-4.5:1 contrast pairs — free accessibility enforcement at the token layer.

## Transforms are trivial (DTCG compliance buys this)

Because the contract is DTCG-compliant, transforms to each consumer are mechanical:

- **Tailwind v4** — a flat CSS-variable-namespace mapping. `@google/design.md` emits the
  `@theme { … }` block directly, so tokens flow into the Astro/Tailwind build with zero
  translation. See [frontend-web](../rules/frontend-web.md).
- **React Native** — a small object mapping over `tokens.json`. See
  [frontend-mobile](../rules/frontend-mobile.md).
- **OG image generator** — reads colors/typography straight from `tokens.json` so social
  cards auto-match the design system. See [seo-discoverability](seo-discoverability.md).

### Fallback if the producer is dropped

If `@google/design.md` is ever replaced, the fallback is a **small script, not a
project**: either **Style Dictionary** or a hand-written transform over the committed
`tokens.json`. The DTCG→Tailwind-v4 mapping is a flat namespace map; the RN theme is a
small object map. Both are a few dozen lines. This is why pinning a producer that may
churn is low-risk — the canonical layer (`tokens.json`) does not move.

## Tokens earn double duty

The same `tokens.json` feeds, with no per-consumer copy:

1. The **web build** — Tailwind v4 `@theme`, shared by the Astro shell and the React SPA
   so they cannot drift.
2. The **OG image generator** — Satori/resvg cards styled from the token colors and
   typography.
3. The **React Native theme** — the mobile app reads the same DTCG currency.

One source, three consumers. Never fork the palette per surface.
