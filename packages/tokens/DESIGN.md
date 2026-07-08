# Design System — Paper & Proof (fleet default)

This is the **EffAz fleet's default visual language**, shipped by the seed kit as
the starting system for every repo. It is a real, complete system — not a
placeholder — and `tokens.json` beside this file is its canonical DTCG
expression. **Per-repo overrides are expected**: revise this brief with the
`design-consultation` skill, regenerate `tokens.json`, and record the departure
in the Decisions Log below. What you must not do is drift from it silently —
the token pipeline and the token-drift gate exist so the system and the code
cannot disagree.

## Product Context

- **What this is:** the default design system for a fleet of developer- and
  agent-facing products (MCP servers with public Astro shells + React SPA app
  layers).
- **Who it's for:** professional developers — and AI agents; the products are
  MCP-native and their pages are read by machines as often as by people.
- **Space/industry:** developer tools / agent infrastructure.
- **Project type:** content-first marketing/docs shells + focused web apps.

## The Memorable Thing (forced decision)

> **Serious tools, quietly excellent.** Engineering craft — restrained, fast,
> exact. The visitor leaves slightly quieter than they arrived.

Every decision below serves this sentence. When a choice arises, the question
is: *which option is quieter, more exact, more evidently cared-for?*

## Aesthetic Direction

- **Direction:** Editorial-instrument ("Paper & Proof") — a printed spec-sheet
  that happens to be alive. Warm paper, exact ink, machine facts in monospace,
  and one green that appears only where something is true.
- **Decoration level:** minimal — hairline rules (1px, `color.border`) do all
  structural work; **no decorative shadows** (one functional `shadow.overlay`
  for floating layers); small radii, square-leaning.
- **Mood:** calm certainty. Braun spec-sheet meets Swiss timetable.
- **Anti-patterns (hard):** no purple gradients, no icon grids, no
  centered-everything heroes, no floating app-window screenshots, no gradient
  CTAs, no dark-by-default cosplay.

## Signature Element (forced decision, per feel.md)

**The verify-tick**: a hairline that draws in (`duration.medium`,
`ease.enter`), then ticks gate-green when a thing is confirmed — a check
passing, a domain verified, a delivery landing. It is the brand's one moment of
motion-as-meaning. Honor `prefers-reduced-motion`: the line renders complete,
the tick shows without animation.

**Feeling target:** *calm certainty* — trust with a faint edge of authority
that resolves into respect.

**Doctrine — the brand has a Content-Type:** this fleet's second audience reads
source, not pixels. The plaintext twin, `llms.txt`, and the MCP manifests are
designed artifacts carrying the same editorial voice as the rendered page. The
kit's first-GET gate already enforces the mechanics; this line makes it brand.

## Typography

All faces are OFL / Google-Fonts-hostable — seeded repos inherit license-clean.

- **Display:** Instrument Serif — headings and pull moments ONLY, never
  paragraphs. The serif is a deliberate risk in a category scared of serifs;
  ration it like the green. Italic for emphasis moments.
- **Body / UI:** Instrument Sans — "quietly excellent" embodied; designed
  sibling of the serif; does all the work without being noticed.
- **Data / Code:** JetBrains Mono — machine facts: code, IDs, latencies,
  tabular numerals, plate captions, uppercase eyebrow labels (11px,
  letter-spacing 0.08–0.12em).
- **Loading:** Google Fonts `<link>` (or self-host subsets); `font-display:
  swap`.
- **Scale:** Tailwind v4 defaults (the quiet choice); display sizes via
  `clamp()` at the hero level only. Line-height 1.6 body, 1.05–1.1 display.

## Color

- **Approach:** restrained — paper, ink, and one rationed accent.
- **Light "Paper" is the default theme** (a deliberate category heresy); dark
  "Bench" ships fully via the `dark` token group (`[data-theme="dark"]`).
- **Ground:** `paper.100` `#F6F4EE` page, `paper.0` white surfaces, hairlines
  `paper.300` `#E4E0D5`. Never pure gray, never pure black.
- **Ink:** `ink.900` `#1C1A16` text, `ink.500` `#6B665B` muted.
- **Accent — gate green:** `green.600` `#16694B` (light) / `green.400`
  `#4CC38F` (dark). It marks *truth*: links, active states, verified marks,
  focus rings. **More than three green elements in a viewport is a failed
  design.** Primary buttons are INK, not green.
- **Semantic:** success = the green family (deliberate doubling — passing IS
  the brand); warning `amber.600` `#8A5A00`; danger `red.600` `#A83A32`; info
  `slate.600` `#4A6478`. Each with a `-wash` surface tone, light and dark.
- **Contrast:** all text-role pairs hold WCAG 2.2 AA on their grounds (the
  producer lint + token descriptions carry the pairings).

## Spacing

- **Base unit:** 4px (`--spacing`), Tailwind multiplier scale.
- **Density:** comfortable on shells; compact is allowed inside data-heavy app
  surfaces.

## Layout

- **Approach:** left-anchored editorial — never centered-everything. Content
  reads top-left to bottom-right, once.
- **Structure:** hairline rules over boxes; specimen panels (real MCP calls,
  real payloads, mono plate captions: "Response, 38 ms — retrieved …,
  unedited") instead of marketing screenshots; a fleet/product index strip
  instead of an icon grid.
- **Max content width:** 1080px shells; fluid app surfaces.
- **Border radius:** `radius.sm` 2 / `md` 4 / `lg` 8 / `xl` 12 / `full` —
  square-leaning, serious.

## Motion

- **Approach:** minimal-functional plus the one signature (verify-tick).
- **Durations:** micro 100ms (state feedback) · short 200ms · medium 320ms
  (spatial) · long 480ms (rare).
- **Easing:** enter `ease.enter` (decelerate) · exit `ease.exit` (accelerate)
  · move `ease.move`.
- **`prefers-reduced-motion` is honored everywhere.** Non-negotiable
  (feel.md).

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-07-07 | Paper & Proof v1 created as the fleet default | design-consultation session: three blind design voices (Claude research + Codex + independent Claude) converged on warm paper / warm ink / one rationed accent / mono-as-craft; accent decided as gate green over vermilion (2-of-3 + semantic ownership: green = checks pass = this fleet's soul); fonts constrained to OFL for seed inheritance. |
