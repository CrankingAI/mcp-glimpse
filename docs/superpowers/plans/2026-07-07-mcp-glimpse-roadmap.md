# mcp-glimpse — Master Build Roadmap

> **For agentic workers:** This is the whole-build roadmap, not a per-task plan. Per meta-agent-md
> `docs/backlog.md §11j` ("plan per phase, not per project — step-level code against a not-yet-built
> tree is fiction"), only **Phase 1** is detailed into bite-sized TDD tasks (see
> `2026-07-07-mcp-glimpse-phase-1-core.md`). Each later phase is a **roadmap row** here and is
> re-planned into its own detailed plan at its boundary, against the tree as it actually exists.

**Goal:** Build and ship `mcp-glimpse` — one polished, open-source Python/FastMCP MCP server that lets
any agent (and its human) *see* its own MCP environment — live at `mcp.mcpglimpse.com/mcp` and on
PyPI, with a two-tab MCP App, an AEO-tuned Learn site at `www.mcpglimpse.com`, and a viral share card.

**Architecture:** A single FastMCP server object exposes the tool/prompt/resource surface over **dual
transport** (stdio for `uvx`, stateful Streamable HTTP for the hosted endpoint). A **pure-function
core** (`model` → `parser` → `analyzer`) turns an optional agent-reported snapshot plus server-observed
connection facts into a **camelCase wire report** consumed by a self-contained `ui://` HTML App. Feedback
and share cards are the only things ever persisted (Azure Table + managed identity). The marketing/Learn
site is static Astro on Azure Static Web Apps; both origins sit behind a Cloudflare proxied edge. The
build itself is executed by an AI fleet (Fable + subagents + workflows) and documented as it happens.

**Tech Stack:** Python 3.13+, `uv`, official `mcp` SDK (FastMCP), Pydantic v2; Vite + TypeScript +
`vite-plugin-singlefile` for the App view; Pillow/resvg for OG images; Astro (static) on Azure Static
Web Apps; Azure Container Apps + Bicep (AVM) + azd; GitHub Actions (OIDC + PyPI trusted publishing);
Cloudflare (edge, DNS, logging Worker).

---

## Global Constraints

Every task in every phase implicitly includes this section. Values are copied verbatim from the brief
(`BUILD_ULTIMATE_MCP_GLIMPSE.md`) and the binding kit (`~/repos/DevPartners/meta-agent-md`).

### Naming & wire contract (append-only public contract)

- **Package / repo / dist:** `mcp-glimpse`; Python module `mcp_glimpse`; server name `mcp-glimpse`.
- **Resource scheme:** `glimpse://…`; App resource URI `ui://glimpse/index.html`.
- **Primary tool name:** `introspect_mcp_context` (proven, consolidated — never rename).
- **Tool & parameter names ARE the public contract.** A rename is a semver-MAJOR breaking change; never
  slip a rename into a patch. Pin every wire name explicitly; describe every parameter.
- **Wire format is camelCase, pinned.** Pydantic models serialize with `by_alias=True, exclude_none=True`.
  `exclude_none` is load-bearing: an undeclared annotation hint must be **omitted (→ `undefined`)**, not
  `null`, or the App misreports every tool as annotated.
- **Tools return a pre-serialized camelCase JSON *string*** with `structured_output=False`. FastMCP's
  unstructured text conversion serializes models by field name (snake_case) and **ignores `by_alias`** —
  returning a string bypasses that. (mcp-lens-python `BUILD-REPORT`, "the #1 trap".)
- **Contract-snapshot test in CI**: freeze tool/prompt/resource names + input schemas as a committed
  fixture; a rename or field drift **fails CI** (kit "blessed" gate, backlog §11c/§13d).
- **Names cached client-side**: on receiving a deprecated field name, emit a **stale-client advisory**;
  parse **alias-tolerantly** (accept old + new, case-insensitive nested keys); **warn on unrecognized
  input, never silently drop it** (a silent drop yields confident-but-wrong output).

### MCP server posture

- **Stateful is a gate, not an option.** Streamable HTTP, **stateful session** — this is what makes
  elicitation/sampling/roots *usable*. Decided up front (kit decisions §24, backlog §13a).
- **Full annotations on every tool** (`readOnlyHint`/`destructiveHint`/`idempotentHint`/`openWorldHint`/
  `title`) — mcp-glimpse must be the best-annotated server its users have.
- Ship `submit_feedback` (kit: an MCP server without it is "incomplete"); durable, never a silent no-op;
  guarded; invite use in the description.
- **v1 is public by design** (no auth). Tab 2 says so explicitly; the edge is the boundary. OAuth2/Descope
  resource-server auth is a documented backlog item, not v1 (brief §12; `/.well-known/oauth-protected-resource`
  only if auth is ever added).
- **Snapshots are never persisted** — analyzed in memory only. Only `submit_feedback` and
  `share_context_card` write anything. Enforced by design (no snapshot logging); stated in App footer + www.
- **No anonymous telemetry in v1** (decision below) — keeps the "never persisted" story absolute.

### Container / ACA ops (every one of these failed only live — bake in day 1)

- `docker build --platform linux/amd64` (Apple-Silicon arm64 → ACA amd64 exits 1, "0 replicas").
- Set **`MCP_ALLOWED_HOSTS`** env for the Python SDK's DNS-rebinding Host allowlist (else `421 Invalid
  Host header` behind the public FQDN). Python-SDK-specific; will hit `mcp.mcpglimpse.com`.
- Deterministic **local build + push + `az containerapp update --image`** over `az containerapp up --source`
  (ACR build-cache staleness ships stale code).
- **`minReplicas ≥ 1`** (scale-to-zero times out interactive connector-adds).
- **Single replica or sticky sessions** (session-bearing transport); ACA MCP app runs `min = max = 1`.
- Durable feedback needs **explicit Storage + user-assigned MI + RBAC**; a container using a user-assigned
  MI with `DefaultAzureCredential` **must** receive `AZURE_CLIENT_ID` in its env, or the Azure path fails
  invisibly (health stays green). Read `AzureWebJobsStorage__tableServiceUri` as an **env var**, not an
  `IConfiguration["a:b"]` key.
- ACA managed environment defaults `publicNetworkAccess: 'Disabled'` → **set `'Enabled'`**.
- The ACA app needs a `registries` block + `AcrPull`; `azd provision` reverts the app to the bicep
  placeholder image (carry the real image as an azd-env param or re-run `az containerapp update --image`).
- **ACA managed cert while the DNS record is Cloudflare-proxied breaks auto-renewal** (~6 months, silent
  expiry). Decide up front: install a **Cloudflare origin certificate** on ACA (renewal-free) *or* document
  the grey-cloud→validate→re-proxy dance. Declare custom domains **in the applied IaC** (`ingress.customDomains`,
  `bindingType: 'Auto'`).

### Health, version, deploy

- `/livez` (liveness, dependency-free), `/readyz` (readiness, checks critical deps + App built), `/version`
  — all **separate from `/mcp`**, unauthenticated. `/readyz` == 200 is part of "definition of done" per deploy.
- Add a **`/readyz` schema sentinel**: render each tool's input schema at boot and fail `/readyz` if a
  known injected/DI param leaks into it (kit §13a-3, adapted as general discipline).
- **`VERSION` file is the single source of truth**; package version + `/version` derive from it. A release
  is git tag `v<VERSION>`; deployed bits, `/version`, and the tag must all agree.
- **Order all commits before the image build** (post-build closeout commits break tag↔bits alignment), or
  rebuild at the tag commit.
- Deploy on `v*` tag push (GitHub Actions, OIDC — no stored Azure secret). Branch pushes run CI gates only.
- Every deploy runs an **end-to-end MCP-client smoke against the deployed URL**; correctness-review runs
  against the **live artifact**, not the diff (kit §12f; caught two real Python parser bugs in mcp-lens).
- **Expect live-only failures**: author + validate locally, then deploy under supervision (kit §11j).

### www / AEO (marketing + Learn)

- **First-GET-without-JS**: a raw `GET` with JS disabled must already contain the JSON-LD + semantic
  markup (answer engines don't render JS). Enforced by a **view-source acceptance test in `check.sh`**.
- Each public route (JS off) must contain: one `<script type="application/ld+json">`, `og:`+`twitter:`
  meta, exactly one `<h1>`, and `<header>/<nav>/<main>/<footer>` landmarks.
- **WCAG 2.2 AA** (accessibility and AEO are the same investment).
- **JSON-LD validation is a CI gate** (`SoftwareApplication`, `TechArticle`/`Article`, `FAQPage`/`QAPage`,
  `WebSite`, `BreadcrumbList`).
- OG images: absolute URL, **1200×630**, always `og:image:alt`; emit Twitter `summary_large_image` too.
- **robots.txt explicitly allows AI crawlers** (GPTBot, ClaudeBot, PerplexityBot, Google-Extended, bingbot).
- Ship `llms.txt` + `llms-full.txt` (root), `sitemap.xml`, RSS/Atom for Learn, IndexNow key + ping-on-publish,
  `/.well-known/security.txt`. Do **not** `Disallow` a `noindex` path (use `X-Robots-Tag` header).

### Edge / observability

- Cloudflare **proxied zone** in front of www **and** the mcp host; SSL/TLS Full (strict); never challenge
  verified bots (kills OG unfurls). Zone posture (`cf-zone-init.sh`) runs **before/with** the first Worker
  deploy (the verified-bot transform-rule headers are load-bearing and otherwise client-spoofable).
- Logging Worker with **verified-bot classification** (reverse-DNS/ASN, free plan), **dual-sink** to Log
  Analytics `EdgeHits_CL` (10-day raw retention) + a **PostHog toggle** (`POSTHOG_ENABLED`, DNT-safe fields,
  geo from `request.cf`, **never IP**). Fail-open (`ctx.waitUntil`, origin served first).
- **Never retain raw client IP**: geo to country/region + city only; App Insights IP masking stays on.
  Client-side PostHog is `/app/*`-only, consent-gated, "Discard client IP data" on. (www has no `/app/*`
  SPA in v1, so client RUM is effectively off; the public shell stays script-free.)

### Cross-cutting

- **MIT license**, public repo from the start, clean history (reference repos stay private donors — port
  ideas and tests, not git history).
- **RFC 9457 Problem Details** on every non-MCP error response (MCP tool failures surface as JSON-RPC /
  `isError` per protocol).
- **Generated-artifact + CI drift gate** pattern (kit §13d, blessed §24): when the same shape is needed on
  both the Python and the TS side, the Python side **emits a committed artifact** the TS side consumes,
  guarded by a regenerate-and-diff test — **never hand-port the logic to a second language**. Applies to the
  App's TypeScript wire types (generate from the Pydantic models; do not hand-mirror as mcp-lens-python did)
  and to the snapshot JSON Schema.
- **DRY, YAGNI, TDD, frequent commits.** Pure core fully unit-tested; the view has no framework.

---

## Decisions resolved (were §13 open questions / kit conflicts)

| # | Question | Decision | Source |
|---|---|---|---|
| D1 | Share-card concept & timing | **Agent Facts** concept (nutrition-label parody); **ships in v1** (Phase 7). Compose a Context-Receipt `TOTAL: ~40K / 200K` footer line into the Facts label. | Owner, this session |
| D2 | www stack | **Astro static on Azure Static Web Apps**, Cloudflare-proxied. | Owner, this session |
| D3 | Feedback store | **Azure Table + managed identity in v1**; optional **GitHub bridge as a fast-follow** behind a flag. | Owner, this session |
| D4 | Anonymous aggregate telemetry | **Skip in v1.** Percentile hook ("more tools than 92%…") stays on the backlog; keeps "never persisted" absolute. | Owner, this session |
| D5 | Auth | **Public by design in v1** (no auth); OAuth2/Descope resource-server is a backlog item. Overrides kit `backend-mcp.md` auth default for this repo — record as ADR. | Brief §4/§8/§12 |
| D6 | Canonical marketing host | **`www.mcpglimpse.com` is canonical; apex `mcpglimpse.com` redirects → `www`.** This **inverts** the kit default (`www → apex`); adjust `cf-zone-init.sh` redirect direction — record as ADR. | Brief §6 (conflicts kit `site-conventions.md`) |
| D7 | Python floor | **3.13+** (brief), above the donor's 3.12. | Brief §5 |
| D8 | `MORE-mcp-lens-FEEDBACK.md` "findings A–D" | **File does not exist** — already absorbed into kit `backlog.md §13a–e` + `decisions.md §24` and deleted on absorption. Those sections ARE the requirements; folded into Global Constraints above. | Kit explorer |
| D9 | Sampling demonstrator shape | **Narrative-of-your-environment** ("your environment, in prose"), rendered in the App; degrades gracefully. | Brief §4.3 (proposed), no objection |

Open items deferred to their phase's brainstorm: whether the App needs a 3rd tab later (Card/History) —
Phase 4 leaves room in the tab bar; GitHub-bridge design — Phase 6 fast-follow.

---

## Kit updates folded in (meta-agent-md edition-5 + Paper & Proof, seeded at v0.7.1)

Captured after the initial plan; these are binding for the phases noted.

- **Design system is the fleet default "Paper & Proof" (`packages/tokens/DESIGN.md`), not from-scratch.**
  Editorial-instrument aesthetic: warm paper (light "Paper" default) + warm ink + one rationed **gate-green
  accent that marks truth** (links, verified marks, focus), Instrument Serif/Sans + JetBrains Mono, hairline
  rules over boxes, signature **verify-tick** (a hairline that ticks gate-green on confirm; honor
  `prefers-reduced-motion`). This maps onto mcp-glimpse's confirmed/annotated/verified moments. **Phase 4**
  (App) and **Phase 9** (www) build *within* it — the Phase 4 judge panel explores options inside Paper &
  Proof, not a new system. Consume via the token pipeline: `tokens.json → theme.css` (`packages/tokens/build.mjs`,
  supports light + `[data-theme="dark"]`, alias refs, motion/shadow/radii), imported as
  `@import "@CrankingAI/tokens/theme.css"` and bound at the **single shadcn `:root` seam** (point each
  shadcn var at a token var — `--primary`=ink not green, `--ring`=green; replace the generated literals).
  Per-repo visual changes go through the `design-consultation` skill and are recorded in DESIGN.md's
  Decisions Log — never silent drift; the **token-drift gate** (`gate_token_drift`, runs in `check.sh` once
  `apps/web` is scaffolded) fails on any hardcoded literal in `:root`.
- **`check.sh` now runs `pnpm -r --if-present test` after the web build** (edition-5): build-output guard
  tests read `dist/`. So **Phase 4/9** must ship a passing Vitest/build-output suite (asserting page counts,
  JSON-LD `@type` presence, corpus markers), or the gate is a no-op that hides drift. (Locally the whole Web
  gate self-skips until `pnpm` is installed.)
- **ACA custom-domain cert = CNAME validation on a subdomain; never TXT** (edition-5 §14d): TXT is the
  apex-behind-a-flattening-proxy escape hatch only; `--validation-method TXT` on `mcp.mcpglimpse.com` is
  CLI-accepted, sits `Pending` ~80 min, then `Failed`, and a `Pending` cert 500s on delete. Binds **Phase 8/10**
  (pairs with the already-chosen Cloudflare-origin-cert stance).
- **AEO tactics are now execution-validated** (edition-5 §14b) — bind **Phase 9**: match JSON-LD `@type` to
  page shape (`QAPage` for question-titled Learn pages; `TechArticle`+**`FAQPage` derived from structured
  data, never hand-written**; `Dataset`/`DefinedTermSet` for reference); emit through **one `jsonLd` layout
  slot**; any combinatorial pages use **canonical ordering only** with links derived from the route slug
  function; **build-output guard tests** assert the corpus from `dist/`; generate `llms.txt`/`llms-full.txt`
  from the **same structured source** as the pages.
- **A third-party form/embed is a privacy-policy event even with zero backend change** (edition-5 §14e) —
  **Phase 9**: if the site adds any embed collecting input, re-run the `privacy-policy-drafter` skill; a "no
  data collected" page is then a ship-blocker.
- **Script hygiene** (edition-5 §14c): quote + `--`-terminate pathspecs for Astro bracketed routes
  (`git add -- 'apps/web/src/pages/[spdx].astro'`) and **assert `git status --porcelain` empty after any
  scripted commit** before declaring success. (Already applied to the Phase 0/1 commits here.)
- **Kit gaps noted for feedback** (stage in `MORE-mcp-glimpse-FEEDBACK.md`, Phase 12):
  (1) the seed's `check.sh` has **no Python lint/test gate** (it covers .NET, pnpm/JS, bicep, markdown);
  mcp-glimpse's Python suite runs via `.github/workflows/ci.yml` (pytest) instead — `check.sh` should grow a
  Python gate (`uv run pytest` / `ruff`) for Python-hosting repos.
  (2) the `check.sh` markdown gate globs `**/*.md` and **lints installed-dependency markdown under `.venv/`**
  (e.g. `starlette`/`httpx` `LICENSE.md` trip MD041), failing a Python repo's gate for files it doesn't own.
  Worked around here with a repo-local `.markdownlint-cli2.jsonc` `ignores` for `.venv/`; the seed should
  ship that ignore (or exclude `.venv` in the `md_lint` glob).

---

## Repository file structure (target)

Seeded from meta-agent-md `seed/` (Phase 0), then the Python app package + ACA bicep + www content are
added per-repo (the seed intentionally ships **no** backend app code or ACA bicep).

```text
mcp-glimpse/
├── AGENTS.md · CLAUDE.md · GEMINI.md · GOAL-STATE.md      # seed: process kit
├── VERSION · SEED_KIT_VERSION · azure.yaml · .mcp.json    # seed
├── README.md · LICENSE (MIT) · SECURITY.md · CONTRIBUTING.md
├── BUILD-LOG.md                                           # "an AI fleet built this" (Phase 12)
├── server.json                                            # MCP registry manifest (Phase 11)
├── pyproject.toml · uv.lock                               # Python app (Phase 1)
├── Dockerfile · .dockerignore                             # multi-stage amd64 (Phase 8)
├── rules/ · docs/ · scripts/                              # seed (check.sh, cf-*.sh, preflight.sh)
├── src/mcp_glimpse/
│   ├── __init__.py · __main__.py · cli.py                 # entry; stdio default, --http (Phase 2)
│   ├── model.py                                           # Pydantic camelCase wire models (Phase 1)
│   ├── parser.py                                          # alias-tolerant snapshot parser (Phase 1)
│   ├── analyzer.py                                        # pure analyzer + signature analyses (Phase 1/3)
│   ├── tokenizer.py                                       # token-cost estimator (Phase 3)
│   ├── poisoning.py                                       # tool-poisoning heuristics (Phase 3)
│   ├── connection.py                                      # server-observed ConnectionFacts + wire facts (Phase 2/5)
│   ├── manifest.py                                        # authoritative name lists, paths, version() (Phase 2)
│   ├── server.py                                          # FastMCP wiring: tools/prompts/resources/routes (Phase 2)
│   ├── prompts.py                                         # 4 prompt builders (Phase 2)
│   ├── feedback.py                                        # guarded store: Local JSONL + Azure Table (Phase 6)
│   ├── sampling.py · roots.py                             # server→client demonstrators (Phase 5)
│   └── card.py                                            # share-card aggregate + OG render (Phase 7)
├── resources/                                             # glimpse:// markdown + snapshot-schema.json (Phase 2)
├── app/                                                   # Vite/TS ui:// view, two tabs (Phase 4)
│   ├── index.html · vite.config.ts · src/*.ts
│   ├── src/types.generated.ts                            # GENERATED from Pydantic (drift gate)
│   ├── smoke.mjs                                          # JS MCP-client end-to-end smoke
│   └── dist/index.html                                   # built single file (gitignored)
├── tests/                                                 # pytest: model/parser/analyzer/feedback/card
├── infra/                                                 # seed AVM starter + per-repo ACA bicep (Phase 8)
│   ├── main.bicep · main.parameters.json · modules/shared.bicep · modules/edge-logs.bicep
│   └── app/aca.bicep                                      # ACA app, registries, customDomains (per-repo)
├── apps/
│   ├── web/                                               # Astro static: marketing + Learn + /c/{id} (Phase 9)
│   └── edge/                                              # Cloudflare logging Worker (Phase 10)
└── .github/workflows/                                     # ci.yml, deploy.yml, publish.yml (Phase 8/11)
```

---

## Phase roadmap

Each phase produces **working, testable software on its own** and ends at a reviewable/deployable gate.
Deploy-bearing phases (8, 9, 10, 11) are "author + validate locally, then deploy under supervision."

| # | Phase | Deliverable (done = …) | Depends on |
|---|---|---|---|
| 0 | Repo scaffold | Seeded tree; `check.sh` green on the skeleton | — |
| 1 | **Pure core** (detailed) | `analyze(parse(json), facts)` → camelCase wire JSON; wire-contract test; ~40 unit tests green | 0 |
| 2 | MCP server surface | `uvx mcp-glimpse` runs (stdio); `--http` serves `/mcp`; 2 tools, 4 prompts, 6+1 resources, health routes; local JS smoke green | 1 |
| 3 | Signature analyses | Context-cost accounting + tool-poisoning lens on the wire, unit-tested | 1 |
| 4 | App view v2 (two tabs) | `?demo=1` renders Panorama + This-Connection; generated TS types drift-gated; `/readyz` checks App built | 2, 3 |
| 5 | Server→client primitives | elicitation (in `submit_feedback`), sampling narrative, `roots/list`, logging/progress/completions/listChanged — each exercised by smoke | 2 |
| 6 | Feedback persistence | `submit_feedback` durable to Azure Table via MI; local JSONL fallback; guard tested | 2 |
| 7 | Share card | `share_context_card` (elicitation-confirmed) → aggregate persisted → `/c/{id}` + server-rendered OG image | 3, 6 |
| 8 | Container + ACA deploy | Live at `mcp.mcpglimpse.com/mcp` (warm, custom domain, cert); deploy CI on `v*`; live smoke green | 4, 5, 6, 7 |
| 9 | www site | `www.mcpglimpse.com` live; ≥6 Learn articles; JSON-LD + llms.txt; demo embed; `/c/{id}` card pages; view-source test green | 7, 8 |
| 10 | Edge + observability | Cloudflare zone + logging Worker live in front of both origins; DNS (apex→www, mcp, www); verified-bot logs flowing | 8, 9 |
| 11 | Publish | On PyPI (trusted publishing) → `uvx mcp-glimpse` from PyPI; listed in the MCP registry via `server.json` | 8 |
| 12 | Quality + launch | Workflow review passes (correctness/security/wire-contract/UX-copy); App design judge panel; BUILD-LOG.md; §10 acceptance met | all |

### Phase details

**Phase 0 — Repo scaffold.** `cp -R ~/repos/DevPartners/meta-agent-md/seed/. .` then run `./scripts/seed-init.sh`
choosing **backend host = container-apps**, **MCP interface = yes**, **web app-layer = none** (www is pure
static Astro, no SPA). Fill every `{{PLACEHOLDER}}` (`grep -rl '{{'`), stamp `SEED_KIT_VERSION`, set `VERSION`
to `0.1.0`, delete `README.seed.md`. Reconcile with the existing repo (keep the current MIT `LICENSE`, the
existing `README.md` becomes the product README in Phase 8). Record ADRs for **D5** (public-by-design) and
**D6** (www canonical / apex→www — invert the kit redirect). Gate: `./scripts/check.sh` green.
*Risk:* seed's `apps/edge` + `infra/modules/edge-logs.bicep` arrive now but aren't wired until Phase 10 —
keep them, don't delete.

**Phase 1 — Pure core.** See `2026-07-07-mcp-glimpse-phase-1-core.md`. Ports `model.py`/`parser.py`/`analyzer.py`
from mcp-lens-python (renamed lens→glimpse), plus the wire-contract snapshot test. **Produces** the
`LensReport`-equivalent `GlimpseReport.to_wire_json()` shape every later phase depends on. No I/O, no FastMCP —
pure TDD.

**Phase 2 — MCP server surface.** `manifest.py` (authoritative `TOOLS`/`PROMPTS`/`RESOURCES` lists, `version()`
from `VERSION`), `connection.py` `observe(ctx)`, `prompts.py` (4 prompts), `server.py` (`build_server()` wiring
2 tools with full annotations + `_meta.ui`, 4 prompts, 6 `glimpse://` resources + 1 `ui://` placeholder,
`/livez`/`/readyz`/`/version` custom routes, `TransportSecuritySettings` from `MCP_ALLOWED_HOSTS`), `cli.py`
(`main()`: stdio default, `--http [--port]`). Copy `resources/*.md` + `snapshot-schema.json` from the donor,
rename scheme. Annotations (from ASP.NET donor): `introspect_mcp_context` → `readOnlyHint:true`,
`idempotentHint:true`, `openWorldHint:false`, `destructiveHint` **unset**, `title:"Introspect MCP / agent
context"`; `submit_feedback` → all four hints `false`, `title:"Submit feedback / feature request / bug"`.
Gate: `app/smoke.mjs` against a locally-run `/mcp` prints `SMOKE OK`; contract-snapshot test asserts the 2
tool names + schemas.

**Phase 3 — Signature analyses (v1 commitments).** (1) **Context-cost accounting** (`tokenizer.py`): estimate
tokens of the agent's tool definitions (names+descriptions+schemas) via one computational base (tiktoken
`o200k_base`, pure-Python) × per-family correction keyed off `snapshot.model.id`, displayed as a **range**
with a method footnote; two honesty caveats in-App (hosts reformat tool defs; caching ≠ freeing window).
Never fabricate `usedTokens`. (2) **Tool-poisoning lens** (`poisoning.py`): heuristic scan of snapshot tool
descriptions for injection directives, exfiltration urges, invisible/bidi Unicode, cross-server shadowing,
suspiciously long descriptions — clearly labeled heuristics, rendered like the consistency lens. Both are
new wire fields on `Analysis`; extend the wire-contract test. Pure functions, fully unit-tested.

**Phase 4 — App view v2 (two tabs).** Vite + TS + `vite-plugin-singlefile` → one CSP-safe HTML file, **never
`innerHTML` on tool data** (XSS). Tab 1 **Agent Panorama** (header stats incl. context-window size + cost
tile; Scope panel; input-warnings banner; capabilities-in-play with honest stateful phrasing; annotation
coverage + per-tool badges; consistency + poisoning lenses; session/environment; tool inventory by server;
insights). Tab 2 **This Connection** (negotiated protocol version, client name/version, session id, transport and
statefulness, negotiated capabilities, HTTP-layer detail, serving facts, this server's own primitives with
annotations; the "everything a server can know about you without your agent telling it" framing). Tab state
client-side; payload carries both tabs. Persistent server chip `mcp-glimpse · Python · vX.Y.Z`. `?demo=1`
fixture. **TS wire types are generated from the Pydantic models** with a regenerate-and-diff CI gate (kit
§13d). Wire the `ui://glimpse/index.html` resource to serve `app/dist/index.html`; `/readyz` 503s if missing.
Design chosen via a Workflow **judge panel** (N variants, scored).

**Phase 5 — Server→client primitives (full matrix, all live).** Fold the ASP.NET donor's `confirm_and_note`
elicitation flow **into `submit_feedback`**: when `ctx`'s negotiated caps include elicitation, `ctx.elicit()`
a one-field boolean confirm ("Record this {kind}: …?"); on accept → record + "recorded"; on decline/cancel →
"not recorded"; **degrade gracefully** to "recorded-unconfirmed" when unsupported. **Sampling** (`sampling.py`):
with client permission, `ctx.session.create_message()` for a one-paragraph narrative of the introspection,
rendered in the App; degrade gracefully. **Roots** (`roots.py`): call `roots/list` when advertised, display
workspace roots. Declare + exercise **logging** (server→client messages during analysis), **progress**
(long renders), **completions** (argument completion for prompt args, e.g. `deep_tool_audit` focus),
**listChanged**. CI smoke must exercise **every** primitive (§10).

**Phase 6 — Feedback persistence.** Port the Functions donor's `TableFeedbackStore`: table `feedback`,
`PartitionKey=Sanitize(kind ∈ feedback|feature-request|bug|praise)`, `RowKey=uuid`, props `Kind/Summary(≤300)/
Detail(≤4000)/Context(≤2000)/ReceivedUtc`, over-cap → `…[truncated]`, empty summary rejected. `DefaultAzureCredential`
with `ManagedIdentityClientId` from `AZURE_CLIENT_ID`; `TableServiceClient(uri, cred)`; read
`AzureWebJobsStorage__tableServiceUri` as an env var. Guard enforced in the abstract base so both backends
inherit it. Local JSONL fallback (`LocalFeedbackStore`) when unconfigured. Fast-follow (flagged): GitHub
Discussions bridge (D3).

**Phase 7 — Share card (v1, D1).** `share_context_card` tool (writes → annotations say so;
**elicitation-confirmed** before persisting): persist only chosen aggregates (servers, tools, destructive
count, annotation coverage, capability flags, `TOTAL: ~cost / window` from Phase 3) — never tool names/desc
unless opted in. Return `mcpglimpse.com/c/{id}`. **OG image rendered server-side in Python** (Pillow or resvg
over an SVG template — same single-file discipline, no headless browser), 1200×630, "Agent Facts" nutrition-label
layout with a Context-Receipt footer. `/c/{id}` page (Phase 9 renders it) carries JSON-LD + "make your own" CTA,
static-cacheable. New Azure Table `cards`.

**Phase 8 — Container + ACA deploy.** Multi-stage `Dockerfile` (node view build → uv runtime, amd64). Per-repo
`infra/app/aca.bicep`: ACA app, `minReplicas=maxReplicas=1`, `publicNetworkAccess:'Enabled'`, `registries` +
`AcrPull`, `AZURE_CLIENT_ID` env from the MI, `MCP_ALLOWED_HOSTS=mcp.mcpglimpse.com`, `ingress.customDomains`
(`bindingType:'Auto'`), Table Storage + MI RBAC (`Storage Table Data Contributor`). Cert stance: **Cloudflare
origin cert** on ACA (renewal-free) — the §11i decision. `deploy.yml` on `v*` tag (OIDC): build once, push,
`az containerapp update --image`, new revision at 0% → smoke `/readyz`==200 + `/version`==tag → shift to 100%;
verify with the `aca-deploy-verification` skill. Gate: live end-to-end MCP smoke against
`https://mcp.mcpglimpse.com/mcp`.

**Phase 9 — www site.** Astro static (D2) on Azure Static Web Apps. Homepage with the App in demo mode
embedded; **≥6 Learn articles** (seed from the `glimpse://` resource copy — What is MCP?; What can a server
see about you?; Tool annotations explained; Elicitation/sampling/roots; Stateless vs stateful; Context-window
cost; Protocol versions; What is an MCP App; Is my agent safe?). Each Learn page: question-as-H1, direct
first-paragraph answer, JSON-LD (`TechArticle`+`FAQPage`), ends with the connect-and-run CTA. `/c/{id}` card
pages. Root files: robots.txt (allow AI crawlers), sitemap.xml, llms.txt + llms-full.txt (from the same
structured source), RSS/Atom, IndexNow key, `/.well-known/security.txt`. Gate: `check.sh` view-source test +
JSON-LD validation green; Heuristic Hero / axe pass at WCAG 2.2 AA.

**Phase 10 — Edge + observability.** `cf-zone-init.sh` (proxied, Full-strict, verified-bot transform rule,
**apex→www 301** per D6). DNS: `www`→SWA, `mcp`→ACA (grey-cloud dance for the ACA cert, then Cloudflare origin
cert), apex→www redirect. Deploy `apps/edge` logging Worker (dual-sink Log Analytics + PostHog toggle, DNT-safe,
verified-bot). `infra/modules/edge-logs.bicep` DCE/DCR/`EdgeHits_CL`. Heed §11i (managed-cert-behind-proxy) —
origin-cert stance already chosen in Phase 8.

**Phase 11 — Publish.** `[project.scripts] mcp-glimpse = "mcp_glimpse.cli:main"`; `publish.yml` on `v*` tag via
**PyPI trusted publishing** (OIDC, no tokens). `server.json` describing the server + two distributions (PyPI for
stdio, remote `mcp.mcpglimpse.com/mcp`); publish with `mcp-publisher` CLI as a release step. Namespace
`io.github.crankingai/mcp-glimpse` (GitHub-verified) or `com.mcpglimpse/glimpse` (DNS TXT). Verify current
registry schema at build time (it's moving).

**Phase 12 — Quality + launch.** Run Workflow quality passes: fan-out review dimensions (correctness / security /
wire-contract / UX-copy) → adversarial verification of each finding → loop-until-dry final audit, **against the
live artifact**. Judge panel already ran on the App design (Phase 4). Write `BUILD-LOG.md` ("an AI fleet built
this"). Stage generalizable findings into `MORE-mcp-glimpse-FEEDBACK.md` for meta-agent-md. Confirm §10 acceptance.

---

## Cross-phase interface: the wire report shape

Phase 1 produces this; Phases 3/5/7 extend it additively (never rename). Full field detail is in the Phase 1
plan. The stable top-level shape:

```text
GlimpseReport {                       # to_wire_json() → camelCase string
  source: str
  snapshot: GlimpseSnapshot | None    # agent-reported; None = server-only view
  connection: ConnectionFacts         # server-observed (Phase 2 fills; Phase 5 adds wire/HTTP facts)
  analysis: Analysis                  # pure-computed (Phase 3 adds contextCost + poisoning)
  warnings: list[str]                 # parser warnings surfaced in the App
}
```

Later phases consume `GlimpseReport` verbatim; the App's generated `types.generated.ts` mirrors it.

---

## Acceptance (Definition of Marvelous — brief §10)

- One Python implementation exposing **every** MCP primitive, each exercised by CI smoke (tools, prompts,
  resources, elicitation, sampling, roots, logging, progress, completions, listChanged).
- Two-tab App renders in ≥2 MCP-Apps hosts (Claude desktop/web + one other); degrades to readable JSON in
  non-App hosts.
- `tools/list` shows full annotations on every tool; wire-contract snapshot test guards it.
- Live at `mcp.mcpglimpse.com/mcp` (warm, custom domain, cert); `www` live with ≥6 Learn articles, llms.txt,
  JSON-LD; repo public with green CI; published to PyPI + MCP registry.
- Cold visitor: www → connect → first rendered introspection in **under two minutes**.

---

## Provenance quick-reference (for phase implementers)

- **Primary donor (port, renamed):** `~/repos/DevPartners/mcp-lens-python` — code is authoritative; its
  README/BUILD-SPEC/BUILD-REPORT are **stale (describe a 3-tool surface)**; the shipped code is the
  consolidated **2-tool** surface. Wire-contract gotcha is documented in its BUILD-REPORT.
- **Elicitation donor:** `~/repos/DevPartners/mcp-lens-aspnet-core` — `confirm_and_note` flow, annotation
  values, stateful `Stateless=false` gate, `ConnectionFacts`.
- **Azure Table donor:** `~/repos/DevPartners/mcp-lens` (Functions) — `TableFeedbackStore`, MI wiring, full
  azd/bicep infra; documents stateless limitations.
- **Binding kit:** `~/repos/DevPartners/meta-agent-md` — `seed/`, `seed/rules/backend-mcp.md`,
  `seed/docs/{seo-discoverability,site-conventions,edge,observability,deployment,health-checks,versioning}.md`,
  `docs/backlog.md §11c/§11i/§11j/§12a/§12d/§12f/§13a–e`, `docs/decisions.md §24`.
- **Note:** the brief's `MORE-mcp-lens-FEEDBACK.md` (findings "A–D") no longer exists — absorbed into kit
  backlog §13 (see D8). Use backlog §13a–e as the requirement source.

```text

