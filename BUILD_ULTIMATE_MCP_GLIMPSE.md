# BUILD: The Ultimate MCP Glimpse

**Status:** brief — tees up the build. Not a spec, not a plan. The build starts by running this
brief through brainstorming → spec → plan → execution (see §9).
**Owner:** Bill Wilder (CrankingAI) · **Drafted:** 2026-07-07 with Claude (Opus 4.8)

---

## 1. Mission

Build **mcp-glimpse**: a single, polished, open-source MCP server that lets any agent — and
its human — *see* the agent's own environment: every connected MCP server, every tool and its
declared annotations, the negotiated capabilities, the context window, the session, the wire.
It is both a genuinely useful tool and a **showcase**: of what a great MCP App looks like, of
every MCP primitive used honestly, and of an AI-fleet build process (Fable + agents + workflows)
producing production-quality OSS.

The one-line pitch: **"Point your agent at itself."**

## 2. Provenance — start here, in this order

1. **`~/repos/DevPartners/meta-agent-md`** — the process kit. Seed a new repo from `seed/`
   (AGENTS.md, GOAL-STATE, rules, docs, scripts, infra bicep). Binding guidance:
   - `seed/rules/backend-mcp.md` — MCP server rules (names ARE the contract; contract-snapshot test)
   - `seed/docs/seo-discoverability.md` — applies to the www site (§8)
   - `docs/backlog.md` §11c, §11i, §11j, §12a, §12d, §12f — SDK drift, ACA certs, live-only
     failures, tool patterns, scale-to-zero, review-against-the-live-artifact
   - `MORE-mcp-lens-FEEDBACK.md` (repo root) — the fleet findings from the mcp-lens build,
     staged for backlog edition 4. Treat findings A–D there as **requirements** for this build.
2. **The three mcp-lens reference implementations** (pattern donors, then superseded):
   - `~/repos/DevPartners/mcp-lens` — .NET Azure Functions (stateless; proved what stateless *can't* do)
   - `~/repos/DevPartners/mcp-lens-python` — idiomatic Python / FastMCP (the stack this build uses)
   - `~/repos/DevPartners/mcp-lens-aspnet-core` — ASP.NET Core stateful (proved elicitation + annotations live)
  mcp-glimpse is the **union of their best features in one implementation**, renamed,
   rethought, and finished. It is a new repo, not a fork; port ideas and tests, not history.

## 3. Non-negotiable lessons (verified the hard way; bake in from day 1)

1. **Stateful is a gate, not an option.** Streamable HTTP, stateful session. This is what makes
   elicitation/sampling/roots *usable* rather than merely reportable. (Functions binding could not
   even emit tool annotations.)
2. **Names are append-only and client-cache-persistent.** Get names right *before* first publish
   (`introspect_mcp_context` rename cost a breaking change). Additive evolution only; alias-tolerant
   input; **warn on unrecognized fields, never silently drop** (silent-drop produces
   confident-but-wrong output); stale-client advisory when deprecated field names arrive.
3. **The wire format is camelCase, pinned.** Pydantic `by_alias=True, exclude_none=True`;
   contract-snapshot test in CI so a rename can never ship silently.
4. **The ui:// view is one self-contained HTML file.** No runtime external requests (CSP-locked
   iframe); never `innerHTML` on tool data (XSS); `_meta.ui.resourceUri` links tool → view;
   `text/html;profile=mcp-app` + `prefersBorder`.
5. **Container/ACA ops checklist** (every one of these failed only live):
   `docker build --platform linux/amd64`; `MCP_ALLOWED_HOSTS` env for the SDK's DNS-rebinding
   Host allowlist (else 421 behind the public FQDN); deterministic local-build+push over
   `az containerapp up --source` (ACR build-cache staleness); **minReplicas ≥ 1** (scale-to-zero
   times out interactive connector-adds); single replica or sticky sessions (session-bearing
   transport); explicit storage + managed identity for durable feedback.
6. **Review against the live artifact.** Unit tests + local smoke are necessary, not sufficient;
   every deploy gets an end-to-end MCP-client smoke against the deployed URL, and correctness
   review subagents run against the real endpoint.

## 4. Product definition

### 4.1 Naming

- **Project / repo / package:** `mcp-glimpse` (rename of mcp-lens; no lens branding remains)
- **Server name:** `mcp-glimpse` · **Resource scheme:** `glimpse://…`
- **Primary tool:** `introspect_mcp_context` (already the proven, consolidated name — keep it)
- Naming review happens at spec time, *before* first publish (lesson §3.2). After first publish,
  the surface is append-only.

### 4.2 Tool surface (small on purpose)

| Tool | Behavior |
|---|---|
| `introspect_mcp_context` | THE tool. Optional `snapshot_json`: with it → full panoramic view across all the agent's servers; without → server-only view. Always renders everything it can. Read-only, idempotent, annotated, `_meta.ui` → the App. |
| `submit_feedback` | Durable feedback/feature/bug channel (Azure Table + managed identity). Guarded, annotated as a non-destructive write. **Elicitation-confirmed when the client supports it** (fold mcp-lens-aspnet's `confirm_and_note` into this tool; degrade gracefully — record + say "unconfirmed"). |

Every tool declares full annotations (`readOnlyHint`/`destructiveHint`/`idempotentHint`/
`openWorldHint`/`title`) — mcp-glimpse must be the best-annotated server its users have.

A likely third tool — `share_context_card` (publish an anonymized, OG-backed share card and
return its URL; **elicitation-confirmed** before anything is persisted) — lands once the share
concept is chosen (§11). Explicit separate tool, not a flag on introspect: it writes, and its
annotations must say so.

### 4.3 MCP primitive coverage — the full matrix, all demonstrated live

- **Tools** — above.
- **Prompts** — port the four (`suggest_explorations`, `full_context_dump`,
  `compare_vantage_points`, `deep_tool_audit`) and tune them to the single-tool surface.
- **Resources** — `glimpse://snapshot-schema` (JSON Schema for `snapshot_json`),
  `explorations`, `primitives`, `what-servers-can-see`, `capabilities`, `protocol-versions`,
  plus the `ui://` App resource.
- **Elicitation** — used (feedback confirmation), reported (capability matrix).
- **Sampling** — **new; none of the three references built it.** A tasteful demonstrator: with
  client permission, ask the client's model for a one-paragraph narrative of the introspection
  result ("your environment, in prose") rendered into the App. Degrades gracefully.
- **Roots** — **new.** Actually call `roots/list` when advertised and display the workspace roots.
- **Logging / progress / listChanged** — declare and exercise: server→client log messages during
  analysis, progress notifications on long renders, `tools/listChanged` correctness.
- **Completions** — argument completion for prompt args (e.g. `deep_tool_audit` focus values).

### 4.4 The App rectangle v2 — two tabs (the fancier ask)

One self-contained `ui://` view with a tab bar:

- **Tab 1 — "Agent Panorama"**: the whole context the agent can see. Everything proven in
  mcp-lens, refined: header stats (tools / servers / dangerous / **context-window size**),
  Scope panel ("N tools on this server · M visible in this agent" + the explainer that an MCP
  server structurally cannot see its siblings — the inventory is agent-reported), input-warnings
  banner, capabilities-in-play (with honest stateful phrasing), annotation coverage + per-tool
  badges, consistency lens (shadow writes), session & environment (client, model, persona, cwd,
  date, platform, active skills), tool inventory grouped by server, insights.
- **Tab 2 — "This Connection"**: only what THIS server can observe first-hand — the wire-level
  vantage no snapshot can fake: negotiated protocol version, client name/version, session id,
  transport + statefulness, negotiated client capabilities, **HTTP-layer detail** (request
  headers of interest: User-Agent, Accept, proto/via; TLS/HTTP version; coarse client IP → geo),
  serving facts (edition badge, instance/revision, region, uptime warm/cold), and this server's
  own tools/prompts/resources with their annotations. Frame it explicitly: *"this is everything
  an MCP server can know about you without your agent telling it — and nothing more."* (That
  sentence is both a feature and the security lesson.)
- Tab state is client-side only; the report payload carries both tabs' data in one shape.
  Persistent server chip (`mcp-glimpse · Python · vX.Y.Z`) stays visible on both tabs.

### 4.5 Behavior carried forward (proven features, port all)

Alias-tolerant snapshot parsing (canonical + short-form names, case-insensitive nested keys);
warnings surfaced in the App (unrecognized field, non-boolean hint, conflicting alias, server
not in `servers[]`, tool skipped); stale-client advisory; shadow-write consistency lens with
word-boundary tokenizer (get_settings ≠ set); vantage-gap analysis; context-window **size**
(never fabricate `usedTokens` — the agent can't know it reliably); demo mode (`?demo=1`).

### 4.6 Signature analyses — **in v1** (promoted from the candidate list)

1. **Context-cost accounting** ⭐ — estimate the token cost of the agent's tool definitions
   themselves (names + descriptions + schemas ≈ tokens, honest "~" labeling) and render it
   against the context window: *"your 178 tools consume ~40K of your 200K before you say a
   word."* Headline tile + per-server breakdown in the Panorama tab. Computable from the
   snapshot alone.
   **Multi-model strategy:** tokenizers differ by family (Claude vs tiktoken vs SentencePiece)
   but only by roughly ±10–25% on prose/JSON — meaningful, not order-of-magnitude. Key the
   estimator off the snapshot's `model.id`: one computational base (e.g. tiktoken `o200k_base`,
   pure-Python, cheap) × per-family correction factor, displayed as a **range** ("~38–46K")
   with a method footnote. Two honesty caveats to state in-App: (a) hosts reformat tool
   definitions into their own prompt syntax before the model sees them, so *any* estimate is
   approximate regardless of tokenizer; (b) prompt caching reduces cost/latency but does NOT
   free window space — occupancy is real either way. Backlog option: exact counts for
   Claude-family via the Anthropic `count_tokens` API (needs a key; overkill for v1).
2. **Tool-poisoning lens** ⭐ — heuristic scan of snapshot tool descriptions: injection-style
   directives ("ignore previous instructions", "always call this tool first"), exfiltration
   urges, invisible/bidi Unicode, cross-server tool-shadowing, suspiciously long descriptions.
   Clearly labeled as heuristics; findings render like the consistency lens.
3. **Privacy stance** — snapshots analyzed in memory, never persisted (only explicit
   `submit_feedback` / `share_context_card` writes anything). Stated in the App footer and on
   www; enforced by design (no snapshot logging).
4. **Sampling + roots demonstrators** — the §4.3 matrix entries are v1 commitments, not
   stretch goals: `roots/list` displayed live; sampling narrative rendered in the App.

## 5. Stack (single implementation, idiomatic Python)

- Python 3.13+, `uv`, official `mcp` SDK (FastMCP), **stateful** Streamable HTTP.
  The fleet build verified FastMCP surfaces everything needed: annotations on tools, `ctx.elicit()`,
  `ctx.session.create_message()` (sampling), `roots/list`, `_meta` on tools/resources.
- Pydantic v2 camelCase wire models; pure-function analyzer/parser core, fully unit-tested.
- View: Vite + TypeScript + `vite-plugin-singlefile` → one HTML file (no framework needed;
  the mcp-lens view pattern is right-sized).
- Container: multi-stage Dockerfile (node view build → uv runtime), amd64.
- Hosting: Azure Container Apps, minReplicas=1, single replica (or sticky sessions), managed
  identity → Table Storage for feedback, `/livez` `/readyz` `/version` routes.
- Also publish to **PyPI** so `uvx mcp-glimpse` runs it locally over **stdio** — dual
  transport (stdio + HTTP) widens the audience to every local MCP host for near-zero cost.
  Mechanics: `[project.scripts] mcp-glimpse = "mcp_glimpse.cli:main"`; CLI defaults to
  `mcp.run(transport="stdio")`, with `--http [--port]` for the hosted mode — same FastMCP server
  object either way. Host config becomes `{"command": "uvx", "args": ["mcp-glimpse"]}`.
  Release via GitHub Actions **trusted publishing** (PyPI OIDC — no long-lived tokens) on tag
  push. One honest nuance: over stdio there is no HTTP layer, so the "This Connection" tab
  degrades gracefully (`transport: stdio`, no headers/geo) — which is itself illustrative and
  should be labeled, not hidden.

## 6. Domains

| Host | Serves |
|---|---|
| `mcp.mcpglimpse.com` | the MCP endpoint (`/mcp`) — ACA custom domain + managed cert; add to `MCP_ALLOWED_HOSTS` |
| `www.mcpglimpse.com` | marketing + Learn site (§8) |
| apex `mcpglimpse.com` | redirect → www |

Target social handle: `@mcpglimpse` on X/Twitter (to be claimed).

DNS per registrar plan already in flight; heed backlog §11i if fronted by Cloudflare (ACA managed
certs vs proxied records).

## 7. OSS repo — `github.com/CrankingAI/mcp-glimpse`

- Public from the start. MIT license. Clean history (new repo; reference repos stay private donors).
- Seeded from meta-agent-md `seed/` (AGENTS.md/CLAUDE.md, GOAL-STATE.md, docs, scripts).
- CI (GitHub Actions): lint + typecheck + pytest + view build + **wire-contract snapshot test**
  (backlog §11c — a tool/field rename fails CI) + MCP-client smoke against a container booted in CI.
- README: 60-second quickstart (hosted endpoint, `uvx`, container), App screenshots, the
  capability matrix, honest security/privacy notes.
- `SECURITY.md`, `CONTRIBUTING.md`, issue templates. `submit_feedback` is the in-band feedback
  channel; GitHub Issues the out-of-band one.
- Publish to the **official MCP registry** (registry.modelcontextprotocol.io) once live — that's
  where hosts discover servers; being an exemplary registry citizen is on-mission. Mechanics:
  a `server.json` in the repo describing the server + its two distributions (the PyPI package
  for local stdio, the remote `mcp.mcpglimpse.com/mcp` endpoint); publish with the official
  `mcp-publisher` CLI as a CI release step. Namespace: `io.github.crankingai/mcp-glimpse`
  (ownership verified via GitHub auth) — or the classier `com.mcpglimpse/glimpse`
  once DNS TXT verification of the domain is set up. Verify current schema/flow against the
  registry docs at build time (it is new and moving).

## 8. `www.mcpglimpse.com` — AEO-tuned marketing + Learn

- Follow `seed/docs/seo-discoverability.md` and the site conventions doc in the kit.
- **AEO tuning:** answer-shaped pages (question-as-H1, direct first-paragraph answer), JSON-LD
  (`FAQPage`, `SoftwareApplication`, `TechArticle`), `llms.txt` + `llms-full.txt`, clean sitemap,
  fast static pages (no client framework needed), canonical URLs.
- **Learn section** (modeled on pragmaticemailvalidator.com / vectorplayground.com): a small
  library of genuinely good explainers that double as answer-engine feedstock. Seed articles —
  much of the copy already exists as the `lens://` resources and can be expanded:
  - What is MCP? Tools vs prompts vs resources
  - What can an MCP server see about you? (the vantage gap — Tab 2's thesis, in prose)
  - Tool annotations explained (readOnlyHint, destructiveHint…) — and why ~1% of tools declare them
  - Elicitation, sampling, and roots: MCP's server→client capabilities
  - Stateless vs stateful MCP transports (what each can and cannot do)
  - How big is your context window — and what do 178 tool definitions cost?
  - MCP protocol versions and capability negotiation
  - What is an MCP App (ui:// / SEP-1865)?
  - Is my agent environment safe? Reading an introspection report
- Every Learn page ends with the same CTA: connect `mcp.mcpglimpse.com/mcp` and run
  `introspect_mcp_context`.
- Live demo embed: the App in demo mode on the homepage, so visitors see the rectangle before
  connecting anything.
- **Root + `/.well-known/` checklist** (kit: `seed/docs/site-conventions.md`, plus
  glimpse-specific items):
  - `robots.txt` — **explicitly allow the AI crawlers** (GPTBot, ClaudeBot, PerplexityBot,
    Google-Extended, bingbot): answer engines are the distribution channel, not the adversary.
  - `sitemap.xml`, `llms.txt` + `llms-full.txt` (root, not .well-known — and per the kit's
    watch-list: ship cheaply, don't oversell), RSS/Atom feed for Learn (feeds are how several
    answer engines find fresh content).
  - **IndexNow** key file + ping-on-publish (Bing's index feeds ChatGPT search/Copilot — cheap
    AEO win).
  - `/.well-known/security.txt` (RFC 9116 — owner adds manually).
  - `/.well-known/mcp-registry-auth` on the apex **if** the registry namespace
    `com.mcpglimpse/*` is taken via HTTP verification (DNS TXT is the alternative).
  - Watch, don't build: MCP `.well-known` discovery proposals (not yet standardized) and A2A
    `/.well-known/agent-card.json` (only if an A2A surface ever exists) — both belong on the
    repo's watch-list per kit convention. `/.well-known/oauth-protected-resource` (RFC 9728)
    applies to the **mcp host** only if auth is ever added; until then Tab 2 says "public by
    design."
- **Edge & analytics** (kit: `seed/docs/edge.md` + `observability.md` — both already solve
  this): Cloudflare proxied zone in front of www AND the mcp host; the kit's logging Worker
  with **verified-bot classification** answers "who's crawling us" (which AI crawlers actually
  fetch `llms.txt` — reverse-DNS/ASN-verified, not UA-trusted), dual-sink to Log Analytics
  (`EdgeHits_CL`, 10-day raw retention) + a **PostHog toggle** (`POSTHOG_ENABLED`, DNT-safe
  fields, geo from `request.cf`, never IP). Client-side PostHog follows the kit's
  observability rules (app layer only, consent-gated, "Discard client IP data" on). Heed
  backlog §11i for the ACA-managed-cert-behind-Cloudflare dance; Cloudflare AI Crawl Control
  stays on the watch-list.

## 9. Build process — Fable, agents, and workflows (the showcase-within-the-showcase)

The *how* is part of the deliverable. Document it as it happens (a `BUILD-LOG.md` or blog post
seed — "an AI fleet built this"):

1. **Brainstorm → spec** (superpowers:brainstorming): resolve the open questions in §11; write
   the design doc. Human gates the spec.
2. **Plan** (superpowers:writing-plans): bite-sized tasks, exact files, TDD steps.
3. **Execute** (superpowers:subagent-driven-development): fresh implementer subagent per task,
   task reviewer per task, model-tiered dispatch.
4. **Workflows for the quality passes** (Claude Code Workflow tool): fan-out review dimensions
   (correctness / security / wire-contract / UX-copy) → adversarial verification of each finding
   (the mcp-lens fleet review caught two real parser bugs unit tests missed) → loop-until-dry on
   the final audit. Use a judge panel on the App's visual design (N variants, scored).
5. **Deploy + live smoke** every increment; review the deployed artifact, not the diff.
6. **Feedback loop:** findings that generalize go back to meta-agent-md via a
  `MORE-mcp-glimpse-FEEDBACK.md` staging file (the kit's fleet-feedback convention).

## 10. Definition of marvelous (acceptance)

- One Python implementation exposing **every** MCP primitive, each demonstrably exercised by the
  CI smoke (tools, prompts, resources, elicitation, sampling, roots, logging, progress,
  completions, listChanged).
- Two-tab App renders correctly in at least two MCP-Apps hosts (Claude desktop/web + one other);
  degrades to readable JSON text in non-App hosts.
- `tools/list` shows full annotations on every tool; the wire-contract snapshot test guards it.
- Live at `mcp.mcpglimpse.com/mcp` (warm, custom domain, cert); `www` live with ≥6 Learn
  articles, llms.txt, JSON-LD; repo public with green CI; published to PyPI + MCP registry.
- A cold visitor can go from www → connect → first rendered introspection in under two minutes.

## 11. The shareable asset — an OG-backed card that pops on social (pick ONE concept at brainstorm)

The growth loop: run introspection → App offers "share this" → agent calls
`share_context_card` → **elicitation confirms** ("publish an anonymized summary card?") → server
persists only the chosen aggregate numbers → returns `mcpglimpse.com/c/{id}` → that page
carries a server-rendered **OG image** so the card unfurls beautifully on X/LinkedIn/Mastodon/
Slack. (The App iframe is CSP-locked — no external requests — so sharing *must* round-trip
through the server via a tool call; that constraint conveniently forces the consent moment.)
Data minimization is the feature: aggregates only, never tool names or descriptions unless
explicitly opted in.

Concepts to weigh (strongest first; "MCP Hygiene Score" was the placeholder — wording felt preachy, so beat it):

| Concept | The card | Why it pops | Watch out |
|---|---|---|---|
| **Context Receipt** ⭐ | Receipt-styled: itemized per-server token costs, `TOTAL: ~40K / 200K (20%)`, `"spent before you said a word"`, timestamp, barcode gag | Receiptify proved the format is inherently viral; it's *your* number, it's surprising, and it showcases the signature feature (§4.6.1) | Costs are estimates — keep the "~" honest |
| **Agent Facts** ⭐ | Nutrition-label parody: "Servers 15 · Tools 178 · Destructive 3 (unlabeled!) · Annotation coverage 1% · Capabilities: elicitation ✓ sampling ✓" | Instantly legible format; carries the annotations/danger story without preachiness; screenshots perfectly | Parody label must stay readable at OG size |
| **Agent Loadout** | RPG character-sheet: servers as gear slots, capability badges (elicitation/sampling/roots) as unlocks, context window as a stat bar | Gamer-culture reach; "show me your loadout" invites replies with *their* cards — the loop feeds itself | Can read as toy; keep one serious stat anchored |
| **Agent Report Card** | A–F grades per dimension (annotation coverage, unlabeled writes, duplicates, injection flags) + one headline GPA | The grade concept from "Hygiene Score" with friendlier framing; drives re-runs ("got my agent to a B+") | Grading rubric must be published or it reads arbitrary |
| **Agent X-Ray** | Skeletal/blueprint scan aesthetic of the server/tool graph | On-brand with "glimpse"; most visually distinctive | Hardest to render well server-side; least numeric |
| **Vantage Card** | One stat, huge: "My agent sees **178 tools**. Each server sees ~4." | The project's thesis in one line; educational virality | Single-note; weaker repeat-share value |

Recommendation: **Agent Facts** favored as the viral lever (owner signal, 2026-07-07) — the
label format carries the annotations/danger story with zero preachiness. **Context Receipt** is
the strong pairing since the concepts compose: a Facts label whose footer carries the receipt's
`TOTAL: ~40K / 200K` line, or vice versa. Settle final composition at brainstorm (§13.1). A
percentile hook ("more tools than 92% of introspected agents") is a powerful add-on *if*
aggregate-count telemetry is accepted (§13.5).

Rendering mechanics: OG image generated server-side in Python (Pillow or resvg over an SVG
template — same single-file discipline as the App view; no headless browser). Card pages are
static-cacheable; `/c/{id}` carries JSON-LD and a "make your own" CTA.

## 12. Backlog (fast follows — not v1)

- **Drift detection** — diff successive snapshots in a session ("2 tools appeared since your
  last introspection"); pairs with honoring `listChanged`.
- **Report export** — downloadable Markdown/JSON from the App → "introspect your agent
  environment in CI" use case.
- **Structured-output introspection** — report which tools declare `outputSchema` (a newer,
  under-adopted contract, like annotations were).
- **Auth introspection** — anonymous-vs-authenticated + OAuth protected-resource metadata;
  at minimum Tab 2 *says* "this server is public by design."
- **Host comparison gallery** (Learn content, not code) — the same server viewed from different
  hosts; writes itself from Tab 2 screenshots.

## 13. Open questions for the brainstorm

1. **Share-card concept** — Agent Facts (owner-favored) vs Context Receipt vs a composition of
   the two (§11); and does v1 ship with the card or land it as the first fast-follow?
2. Sampling demonstrator shape — narrative-of-your-environment (proposed) or something sharper?
3. www stack — static (Astro/plain) on Azure Static Web Apps vs ACA-hosted; kit conventions apply.
4. Feedback store — Azure Table (proven) vs something visible-in-public (e.g., GitHub Discussions
   bridge) for an OSS project?
5. Anonymous aggregate telemetry (counts only) — needed for the percentile hook; worth the
   privacy-copy cost, or skip?
6. Does the App need a third tab later (Card / History), and does the tab design leave room?
