# Frontend — Mobile

Self-contained. Deleting any sibling rule leaves no broken links here.

Mobile is **React Native**. It shares the same design system and the same React
idioms as the web app layer.

## Design tokens

React Native consumes the **same canonical DTCG `tokens.json`** as the web layers
(DTCG is the shared currency across web and mobile). The RN theme is a small
mapping over that committed `tokens.json` — no separate token source, no drift.
Full pipeline, producer, and version-pinning: [design-md.md](../docs/design-md.md).

## React idioms (hard rules)

Identical to the web rule in [frontend-web.md](frontend-web.md):

- Functional components, hooks, and refs only.
- **No vanilla imperative manipulation of nodes React owns.** Drive UI through
  state and props.
- **Imperative escape hatches only where the platform genuinely requires them** —
  e.g. focus, animation drivers, native module bridges, camera/sensor APIs,
  measurement, and third-party native widgets. These are allowed; **document each
  one inline** at the call site explaining why RN cannot own it.
