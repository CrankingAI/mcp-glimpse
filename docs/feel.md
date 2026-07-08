# Feel — the product must feel like something

The kit's gates guarantee a repo is correct, operable, and indexable. None of
that makes anyone *feel* anything. This doc is the floor for product feel:
gate-able where possible, a forced decision where not.

## The signature element (forced decision)

`DESIGN.md` MUST name two things (the design-consultation skill elicits them):

- **One signature element** — the interaction or visual this product does that
  no component-library default gives you.
- **A feeling target** — "after first run, the user should feel ___."

The seed's `packages/tokens/DESIGN.md` ships with the fleet defaults already
named — signature: the **verify-tick** (a hairline draws, then ticks
gate-green when a thing is confirmed); feeling target: **calm certainty**.
Keeping them is a fine choice for a fleet-family product; replacing them per
repo is the expected override, recorded in the DESIGN.md Decisions Log.

shadcn/ui is the kit's component layer and a fine app-layer default — and the
default aesthetic of every AI-generated product in 2026. The `/app/*` layer
may look conventional; the **public shell is where the design system must
diverge from the defaults**. That divergence is the signature element.

## Motion

- **Motion tokens live in `tokens.json`** — DTCG has first-class `duration`
  and `cubicBezier` types; same source as color and type, no per-surface forks
  (see [design-md](design-md.md)).
- Durations: ~100–200 ms for state feedback, ~200–400 ms for spatial change;
  one easing family product-wide.
- **`prefers-reduced-motion` is honored everywhere.** Non-negotiable.
- Animate compositor properties (`transform`, `opacity`), not layout.

## Loading and perceived performance

- **Skeletons over spinners**, and reserve the space — loading never shifts
  layout.
- **Optimistic UI is the default** for mutations the user just made (TanStack
  Query supports this natively); reconcile on settle.
- The public shell's speed is a feel *and* AEO investment: it is static by
  construction — keep it that way (no script creep; see
  [seo-discoverability](seo-discoverability.md)).

## Empty states and errors are designed surfaces

- An empty state says **what this is, why it's empty, and the next action** —
  never a blank panel or a bare "No items".
- **Problem-details `detail` strings are UI copy.** RFC 9457 fixes the shape;
  this doc governs the words: human, specific, next-step-bearing. "An error
  occurred" is a defect, not a message.

## Verification

Feel regressions don't fail builds — audit them. Run a periodic design /
heuristic review against `DESIGN.md` (the design-review class of skills /
tooling), with the same cadence discipline as the
[operational to-do list](operations.md).
