import { el } from "./dom.js";
import type { GlimpseReport, ToolRef, PoisoningFinding } from "./types.generated.js";

const root = () => document.getElementById("root")!;

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

// Humanize a token count: 200000 -> "200K", 1000000 -> "1M". We show sizes we actually know,
// never a guessed usage figure.
function humanK(n?: number | null): string {
  if (n == null) return "—";
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(n % 1_000_000 ? 1 : 0)}M`;
  if (n >= 1000) return `${Math.round(n / 1000)}K`;
  return String(n);
}

// A token range that shares one suffix where possible: (38000, 46000) -> "38–46K".
function humanRange(low?: number | null, high?: number | null): string {
  const ls = humanK(low), hs = humanK(high);
  const suf = /[KM]$/.exec(hs)?.[0];
  if (suf && ls.endsWith(suf)) return `${ls.slice(0, -1)}–${hs}`;
  return `${ls}–${hs}`;
}

function uptime(startedIso?: string | null): string {
  if (!startedIso) return "";
  const t = Date.parse(startedIso);
  if (isNaN(t)) return "";
  const secs = Math.max(0, Math.round((Date.now() - t) / 1000));
  if (secs < 45) return `${secs}s (cold)`;
  if (secs < 3600) return `${Math.round(secs / 60)}m (warm)`;
  if (secs < 86400) return `${Math.round(secs / 3600)}h (warm)`;
  return `${Math.round(secs / 86400)}d (warm)`;
}

// ---------------------------------------------------------------------------
// Annotations — shared between the coverage panel and the tool inventory
// ---------------------------------------------------------------------------

const HINTS: Array<{ key: keyof ToolRef; label: string; kind: string }> = [
  { key: "readOnlyHint", label: "read-only", kind: "read" },
  { key: "idempotentHint", label: "idempotent", kind: "idem" },
  { key: "openWorldHint", label: "open-world", kind: "open" },
  { key: "destructiveHint", label: "destructive", kind: "destruct" },
];

// A tool is "annotated" (a confirmed thing → earns the verify-tick) if it declared any hint or title.
function isAnnotated(t: ToolRef): boolean {
  return t.readOnlyHint != null || t.destructiveHint != null || t.idempotentHint != null
    || t.openWorldHint != null || t.title != null;
}

function annotationBadges(t: ToolRef): HTMLElement[] {
  const out: HTMLElement[] = [];
  if (t.title) out.push(el("span", { class: "badge badge--title", title: "annotation title" }, `“${t.title}”`));
  for (const h of HINTS) {
    if ((t[h.key] as boolean | undefined) === true) {
      out.push(el("span", { class: `badge badge--${h.kind}`, title: `${String(h.key)}: true` }, h.label));
    }
  }
  if (!isAnnotated(t)) {
    out.push(el("span", { class: "badge badge--none", title: "declares no MCP annotations" }, "no annotations"));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Small building blocks
// ---------------------------------------------------------------------------

function statTile(num: number | string, label: string, danger = false): HTMLElement {
  return el("div", { class: `stat${danger ? " stat--danger" : ""}` },
    el("div", { class: "stat__num" }, String(num)),
    el("div", { class: "stat__label" }, label));
}

function panel(eyebrow: string, ...kids: (Node | string | null | undefined)[]): HTMLElement {
  return el("div", { class: "panel" }, el("div", { class: "eyebrow" }, eyebrow), ...kids);
}

// The persistent identity chip — which mcp-glimpse server (and edition) produced this view.
// This is one of the rationed green elements: it marks the verifier's own identity.
function serverChip(r: GlimpseReport): HTMLElement {
  const c = r.connection;
  const parts = [c.serverName ?? "mcp-glimpse"];
  if (c.serverEdition) parts.push(c.serverEdition);
  parts.push(`v${c.serverVersion ?? "0.0.0"}`);
  return el("span", { class: "chip chip--server", title: "the MCP server that produced this view" },
    el("span", { class: "dot" }), parts.join(" · "));
}

// ===========================================================================
// TAB 1 — Agent Panorama (the whole context the agent can see)
// ===========================================================================

function statsRow(r: GlimpseReport): HTMLElement {
  const a = r.analysis;
  const windowTokens = r.snapshot?.contextWindow?.totalTokens ?? a.contextCost?.windowTotalTokens;
  return el("div", { class: "stats" },
    statTile(a.totalTools ?? 0, "Tools"),
    statTile(a.totalServers ?? 0, "Servers"),
    statTile(a.dangerousToolCount ?? 0, "Dangerous", (a.dangerousToolCount ?? 0) > 0),
    statTile(humanK(windowTokens), "Context window"));
}

// "~38–46K of 200K before you say a word." — the cost of the tools that sit in the window
// before the user types anything. The "~" is deliberate honesty; the method is footnoted.
function costTile(r: GlimpseReport): HTMLElement | null {
  const cc = r.analysis.contextCost;
  if (!cc || (cc.estimatedTokensLow == null && cc.estimatedTokensHigh == null)) return null;
  const range = humanRange(cc.estimatedTokensLow, cc.estimatedTokensHigh);
  const win = humanK(cc.windowTotalTokens ?? r.snapshot?.contextWindow?.totalTokens);
  const card = el("div", { class: "cost" },
    el("div", { class: "eyebrow", style: "margin-bottom:8px" }, "Context cost · before you say a word"),
    el("div", {},
      el("span", { class: "cost__range" }, `~${range}`),
      el("span", { class: "cost__of" }, `  of ${win} token window`)));
  if (cc.method) {
    const fam = cc.modelFamily ? `${cc.modelFamily} family — ` : "";
    card.appendChild(el("div", { class: "cost__foot" }, `${fam}${cc.method}`));
  }
  return card;
}

// The narrative — "your environment, in prose" — as a quiet serif pull-quote when present.
function narrativePull(r: GlimpseReport): HTMLElement | null {
  const text = r.narrative?.trim();
  if (!text) return null;
  return el("figure", { class: "panel", style: "margin:0" },
    el("blockquote", { class: "pull" }, text),
    el("figcaption", { class: "pull__cap" }, "your environment, in prose — sampled narrative"));
}

function warningsBanner(r: GlimpseReport): HTMLElement | null {
  const ws = r.warnings ?? [];
  if (ws.length === 0) return null;
  const shown = ws.slice(0, 6);
  return el("div", { class: "panel panel--warn" },
    el("div", { class: "eyebrow" }, `⚠ ${ws.length} input warning${ws.length === 1 ? "" : "s"}`),
    el("ul", { class: "list" },
      ...shown.map((w) => el("li", { class: "mono" }, w)),
      ...(ws.length > shown.length ? [el("li", { class: "hint" }, `…and ${ws.length - shown.length} more`)] : [])));
}

// Scope: the vantage gap. A server structurally cannot enumerate its siblings, so the panorama
// is agent-reported, not observed.
function scopePanel(r: GlimpseReport): HTMLElement {
  const vg = r.analysis.vantageGap ?? {};
  const serverSees = vg.serverSees ?? 0;
  const agentSees = vg.agentSees ?? (r.snapshot?.tools?.length ?? 0);
  return panel("Scope",
    el("div", {},
      el("b", {}, String(serverSees)), ` tool${serverSees === 1 ? "" : "s"} on this server · `,
      el("b", {}, String(agentSees)), " visible in this agent."),
    el("p", { class: "hint", style: "margin:8px 0 0" },
      "An MCP server can only see its own tools — the protocol gives it no way to enumerate the host's other connected servers. The inventory below is what the ",
      el("b", {}, "agent"), " reports it can see across all of them, not something this server observed."));
}

function capabilitiesPanel(r: GlimpseReport): HTMLElement {
  const cc = r.snapshot?.clientCapabilities ?? {};
  const conn = r.connection;
  const has = {
    tools: (r.analysis.totalTools ?? 0) > 0 || (conn.serverTools?.length ?? 0) > 0,
    prompts: (r.analysis.serversOfferingPrompts ?? 0) > 0 || (conn.serverPrompts?.length ?? 0) > 0,
    resources: (r.analysis.serversOfferingResources ?? 0) > 0 || (conn.serverResources?.length ?? 0) > 0,
    sampling: cc.sampling === true, elicitation: cc.elicitation === true, roots: cc.roots === true,
  };
  const cell = (label: string, on: boolean) => el("span", { class: `chip ${on ? "" : "dim"}` }, label);
  const card = panel("Capabilities in play",
    el("div", { style: "display:flex;gap:6px;flex-wrap:wrap" },
      cell("tools", has.tools), cell("prompts", has.prompts), cell("resources", has.resources),
      cell("sampling", has.sampling), cell("elicitation", has.elicitation), cell("roots", has.roots)));

  const clientSide = [has.sampling && "sampling", has.elicitation && "elicitation", has.roots && "roots"]
    .filter(Boolean) as string[];
  if (clientSide.length > 0) {
    card.appendChild(el("p", { class: "hint", style: "margin:10px 0 0" },
      `Your client advertises ${clientSide.join(", ")} — capabilities that only mean something inside a live bidirectional session; a server can't reach back through them on its own.`));
  }
  return card;
}

// Annotation coverage + tallies. The coverage meter (green) is the "share of tools that told the
// truth about themselves"; the number is INK — green stays a rationed accent.
function coveragePanel(r: GlimpseReport): HTMLElement {
  const tools = r.snapshot?.tools ?? [];
  const total = tools.length;
  const annotated = r.analysis.annotatedToolCount ?? tools.filter(isAnnotated).length;
  const pct = total ? Math.round((annotated / total) * 100) : 0;
  const counts = {
    read: tools.filter((t) => t.readOnlyHint === true).length,
    idem: tools.filter((t) => t.idempotentHint === true).length,
    open: tools.filter((t) => t.openWorldHint === true).length,
    destruct: tools.filter((t) => t.destructiveHint === true).length,
    title: tools.filter((t) => !!t.title).length,
  };
  const tally = (label: string, n: number, kind: string) => el("span", { class: `badge badge--${kind}` }, `${label} ${n}`);
  const hidden = r.analysis.annotationVisibility?.verdict === "hidden";
  const card = panel("Annotation coverage",
    el("div", {}, el("b", {}, `${annotated} of ${total}`), hidden
      ? ` tools reached the agent with annotations (${pct}%)`
      : ` tools declare annotations (${pct}%)`),
    el("div", { class: "cov" }, el("div", { class: "cov__fill", style: `width:${Math.max(2, pct)}%` })),
    el("div", { class: "badges" },
      tally("read-only", counts.read, "read"),
      tally("idempotent", counts.idem, "idem"),
      tally("open-world", counts.open, "open"),
      tally("destructive", counts.destruct, "destruct"),
      tally("titled", counts.title, "title")));
  // Ground truth from mcp-glimpse's own tools: did declared annotations survive the trip to the
  // agent? When they didn't, "unannotated" says nothing about what servers actually declare.
  const vis = r.analysis.annotationVisibility;
  if (vis) {
    card.appendChild(el("p", { class: "hint", style: "margin:10px 0 0" },
      el("b", {}, vis.verdict === "hidden" ? "Host hides annotations. " : vis.verdict === "partial" ? "Partial snapshot. " : "Verified. "),
      vis.detail));
  }
  const unannotated = r.analysis.unannotatedToolCount ?? (total - annotated);
  if (unannotated > 0 && !hidden) {
    card.appendChild(el("p", { class: "hint", style: "margin:10px 0 0" },
      `${unannotated} tool${unannotated === 1 ? "" : "s"} declare no annotations — on the wire, the server can't tell a read from a write.`));
  }
  return card;
}

// Consistency lens — declared annotations that contradict a tool's own name. Heuristic.
function consistencyPanel(r: GlimpseReport): HTMLElement | null {
  const items = r.analysis.inconsistencies ?? [];
  if (items.length === 0) return null;
  return el("div", { class: "panel panel--flag" },
    el("div", { class: "eyebrow" }, `⚑ ${items.length} annotation inconsistenc${items.length === 1 ? "y" : "ies"} · heuristic`),
    el("ul", { class: "list" }, ...items.map((t) => el("li", { class: "hint" }, t))),
    el("p", { class: "hint", style: "margin:8px 0 0" },
      "A tool's declared annotations disagree with what its name implies — trust the behaviour, not the label."));
}

const POISON_LABELS: Record<string, string> = {
  injection: "prompt injection",
  exfiltration: "data exfiltration",
  "hidden-unicode": "hidden unicode",
  shadowing: "tool shadowing",
  "excessive-length": "excessive length",
};

// Tool-poisoning lens — grouped by category. Heuristic, and labelled as such.
function poisoningPanel(r: GlimpseReport): HTMLElement | null {
  const items = r.analysis.toolPoisoning ?? [];
  if (items.length === 0) return null;
  const byCat = new Map<string, PoisoningFinding[]>();
  for (const f of items) {
    const list = byCat.get(f.category) ?? [];
    list.push(f);
    byCat.set(f.category, list);
  }
  const card = el("div", { class: "panel panel--flag" },
    el("div", { class: "eyebrow" }, `☢ ${items.length} tool-poisoning signal${items.length === 1 ? "" : "s"} · heuristic`));
  for (const [cat, list] of byCat) {
    const group = el("div", { style: "margin-top:10px" },
      el("div", { class: "badges", style: "margin-bottom:4px" },
        el("span", { class: "badge badge--destruct" }, POISON_LABELS[cat] ?? cat),
        el("span", { class: "badge" }, `${list.length}`)));
    for (const f of list) {
      group.appendChild(el("div", { class: "hint", style: "margin:4px 0" },
        el("span", { class: "mono", style: "color:var(--fg)" }, f.tool), " — ", f.detail));
    }
    card.appendChild(group);
  }
  card.appendChild(el("p", { class: "hint", style: "margin:10px 0 0" },
    "Pattern-matched from tool names and descriptions — a signal to review, not a verdict."));
  return card;
}

// Per-server context-cost breakdown — which servers are spending your window.
function perServerCostPanel(r: GlimpseReport): HTMLElement | null {
  const per = r.analysis.contextCost?.perServer ?? [];
  if (per.length === 0) return null;
  const rows = [...per].sort((a, b) => (b.estimatedTokens ?? 0) - (a.estimatedTokens ?? 0));
  const max = Math.max(1, ...rows.map((s) => s.estimatedTokens ?? 0));
  const card = panel("Per-server context cost");
  for (const s of rows) {
    const tk = s.estimatedTokens ?? 0;
    card.appendChild(el("div", { style: "margin-top:8px" },
      el("div", { style: "display:flex;justify-content:space-between;gap:8px" },
        el("span", { class: "mono", style: "font-size:12.5px" }, s.name ?? "(unknown)"),
        el("span", { class: "mono muted", style: "font-size:12px" }, `~${humanK(tk)}`)),
      el("div", { class: "cov", style: "margin:5px 0 0;background:var(--line)" },
        el("div", { style: `height:100%;border-radius:var(--r-full);background:var(--line-strong);width:${Math.max(2, Math.round((tk / max) * 100))}%` }))));
  }
  return card;
}

// Session & environment — ambient facts the agent carries, surfaced from the snapshot.
function sessionPanel(r: GlimpseReport): HTMLElement | null {
  const s = r.snapshot;
  if (!s) return null;
  const rows: HTMLElement[] = [];
  const kv = (label: string, value?: string | null) => {
    if (!value) return;
    rows.push(el("div", { class: "kv__k" }, label));
    rows.push(el("div", { class: "kv__v" }, value));
  };
  kv("client", s.host ? `${s.host.name ?? "?"}${s.host.version ? " " + s.host.version : ""}` : null);
  kv("model", s.model?.displayName ?? s.model?.id ?? null);
  kv("acting as", s.persona?.name ?? null);
  kv("cwd", s.environment?.cwd ?? null);
  kv("date", s.environment?.date ?? null);
  kv("platform", [s.environment?.platform, s.environment?.osVersion].filter(Boolean).join(" · ") || null);
  const skills = s.skills ?? [];
  if (rows.length === 0 && skills.length === 0) return null;
  const card = panel("Session & environment", el("div", { class: "kv" }, ...rows));
  if (skills.length > 0) {
    card.appendChild(el("div", { style: "margin-top:12px" },
      el("div", { class: "kv__k", style: "margin-bottom:6px" }, "active skills"),
      el("div", { class: "badges" }, ...skills.map((sk) => el("span", { class: "chip" }, sk)))));
  }
  return card;
}

// Cross-server signals worth a glance (duplicates, the heaviest server).
function crossServerPanel(r: GlimpseReport): HTMLElement | null {
  const a = r.analysis;
  const items: (Node | string)[] = [];
  if (a.largestServer?.name) {
    items.push(el("li", { class: "hint" }, `Heaviest server: `, el("b", {}, a.largestServer.name), ` (${a.largestServer.toolCount ?? 0} tools).`));
  }
  if ((a.duplicateToolNames ?? []).length) {
    items.push(el("li", { class: "hint" }, `Duplicate tool name${a.duplicateToolNames!.length === 1 ? "" : "s"} across servers: `, el("span", { class: "mono" }, a.duplicateToolNames!.join(", ")), " — the agent must disambiguate which server to call."));
  }
  if ((a.serversOfferingResources ?? 0) > 0) {
    items.push(el("li", { class: "hint" }, `${a.serversOfferingResources} server${a.serversOfferingResources === 1 ? "" : "s"} also expose resources.`));
  }
  if (items.length === 0) return null;
  return panel("Cross-server signals", el("ul", { class: "list" }, ...items));
}

// Tool inventory grouped by server, each tool carrying its annotation badges and verify-tick.
function inventoryPanel(r: GlimpseReport): HTMLElement {
  const tools = r.snapshot?.tools ?? [];
  const card = panel("Tool inventory");
  if (tools.length === 0) {
    card.appendChild(el("p", { class: "hint", style: "margin:0" },
      "No agent-supplied tools — this is the server-only view. Run the full_context_dump prompt and call introspect_mcp_context to see everything the agent can."));
    return card;
  }
  const byServer = new Map<string, ToolRef[]>();
  for (const t of tools) {
    const k = t.server ?? "(unknown)";
    const list = byServer.get(k) ?? [];
    list.push(t);
    byServer.set(k, list);
  }
  for (const [server, list] of byServer) {
    const group = el("div", { class: "server-group" },
      el("div", { class: "server-head" },
        el("b", {}, server),
        el("span", { class: "mono muted", style: "font-size:11.5px" }, `${list.length} tool${list.length === 1 ? "" : "s"}`)));
    for (const t of list) {
      const danger = t.destructiveHint === true || t.openWorldHint === true;
      const annotated = isAnnotated(t);
      group.appendChild(el("div", { class: `tool tick${annotated ? " tick--on" : ""}${danger ? " tool--danger" : ""}`, title: t.description ?? t.name },
        el("span", { class: "tool__name" }, t.name),
        el("span", { class: "badges" }, ...annotationBadges(t))));
    }
    card.appendChild(group);
  }
  return card;
}

function panoramaPanel(r: GlimpseReport): HTMLElement {
  if (!r.snapshot) {
    return el("div", { class: "stack" },
      el("div", { class: "state" },
        el("div", { class: "eyebrow" }, "Agent Panorama"),
        el("h2", {}, "Server-only view"),
        el("p", { class: "hint" },
          "No agent snapshot was supplied, so there is no panorama to draw. This connection only sees its own vantage — open ",
          el("b", {}, "This Connection"), " for the first-hand facts. To populate this tab, run the full_context_dump prompt and call introspect_mcp_context with everything the agent can see.")));
  }
  return el("div", { class: "stack" },
    statsRow(r),
    costTile(r),
    narrativePull(r),
    warningsBanner(r),
    scopePanel(r),
    capabilitiesPanel(r),
    coveragePanel(r),
    consistencyPanel(r),
    poisoningPanel(r),
    perServerCostPanel(r),
    sessionPanel(r),
    crossServerPanel(r),
    inventoryPanel(r));
}

// ===========================================================================
// TAB 2 — This Connection (only what THIS server observes first-hand)
// ===========================================================================

function kvGrid(pairs: Array<[string, HTMLElement | string | null]>): HTMLElement {
  const rows: HTMLElement[] = [];
  for (const [k, v] of pairs) {
    if (v == null) continue;
    rows.push(el("div", { class: "kv__k" }, k));
    rows.push(el("div", { class: "kv__v" }, v));
  }
  return el("div", { class: "kv" }, ...rows);
}

function notSurfaced(v?: string | null): HTMLElement | string {
  return v ? v : el("span", { class: "muted" }, "not surfaced");
}

function chipList(label: string, items?: string[]): HTMLElement {
  const list = items ?? [];
  const body = list.length
    ? el("div", { class: "badges", style: "margin-top:6px" }, ...list.map((x) => el("span", { class: "chip" }, x)))
    : el("p", { class: "hint", style: "margin:6px 0 0" }, "none");
  return el("div", { style: "margin-top:12px" }, el("div", { class: "kv__k" }, label), body);
}

function connectionPanel(r: GlimpseReport): HTMLElement {
  const c = r.connection;
  const transport = c.transport ?? null;
  const isStdio = (transport ?? "").toLowerCase() === "stdio";

  const framing = el("figure", { class: "panel", style: "margin:0" },
    el("blockquote", { class: "pull" },
      "This is everything an MCP server can know about you without your agent telling it — and nothing more."));

  const negotiated = panel("Negotiated",
    kvGrid([
      ["protocol", notSurfaced(c.protocolVersion)],
      ["client", c.clientName ? `${c.clientName}${c.clientVersion ? " " + c.clientVersion : ""}` : notSurfaced(c.clientName)],
      ["session id", notSurfaced(c.sessionId)],
      ["transport", el("span", {}, notSurfaced(transport))],
    ]));
  negotiated.appendChild(el("p", { class: "hint", style: "margin:10px 0 0" },
    isStdio
      ? el("span", {}, el("b", {}, "stdio transport"), " — the server speaks over pipes, so there is no HTTP layer: no request headers, no IP, no geolocation to read. The wire is narrow by construction.")
      : el("span", {}, "A ", el("b", {}, "session id"), " present means a stateful connection the server can address over time; absent, each call stands alone.")));

  const up = uptime(c.serverStartedUtc);
  const serving = panel("Serving facts",
    kvGrid([
      ["server", `${c.serverName ?? "mcp-glimpse"} v${c.serverVersion ?? "0.0.0"}`],
      ["edition", notSurfaced(c.serverEdition)],
      ["instance", notSurfaced(c.serverInstance)],
      ["started", notSurfaced(c.serverStartedUtc)],
      ["uptime", up ? el("span", {}, up) : notSurfaced(null)],
    ]));

  const primitives = panel("This server's own primitives",
    el("p", { class: "hint", style: "margin:0" },
      "The tools, prompts and resources ", el("b", {}, "this"), " server actually exposes — first-hand, not agent-reported."),
    chipList("tools", c.serverTools),
    chipList("prompts", c.serverPrompts),
    chipList("resources", c.serverResources));

  const roots = r.connection.roots ?? [];
  const rootsPanel = panel("Workspace roots",
    roots.length
      ? el("div", { style: "display:flex;flex-direction:column;gap:4px" },
          ...roots.map((p) => el("span", { class: "mono", style: "font-size:12.5px" }, p)))
      : el("p", { class: "hint", style: "margin:0" }, "No workspace roots were shared with this server."));
  rootsPanel.appendChild(el("p", { class: "hint", style: "margin:10px 0 0" },
    "Roots are the folders your client has offered this connection — the live edge of what it may touch."));

  return el("div", { class: "stack" }, framing, negotiated, serving, primitives, rootsPanel);
}

// ===========================================================================
// Shell + tabs
// ===========================================================================

function headerBlock(r: GlimpseReport): HTMLElement {
  const a = r.analysis;
  const s = r.snapshot;
  const model = s?.model?.displayName ?? s?.model?.id ?? "unknown model";
  const title = s
    ? `${a.totalTools ?? 0} tools across ${a.totalServers ?? 0} servers`
    : "This connection, first-hand";
  return el("header", {},
    el("div", { style: "margin-bottom:8px" }, serverChip(r)),
    el("div", { class: "eyebrow" }, `MCP Glimpse · ${r.source}`),
    el("h1", { class: "title" }, title),
    el("div", { class: "subline" }, `${model} · protocol ${r.connection.protocolVersion ?? "not surfaced"}`));
}

export function render(r: GlimpseReport) {
  // The panorama needs a snapshot; when there isn't one, land on This Connection.
  const startTab: "panorama" | "connection" = r.snapshot ? "panorama" : "connection";

  const panorama = panoramaPanel(r);
  const connection = connectionPanel(r);

  const tabPanorama = el("button", { class: "tab", role: "tab", id: "tab-panorama", "aria-controls": "panel-panorama", type: "button" }, "Agent Panorama");
  const tabConnection = el("button", { class: "tab", role: "tab", id: "tab-connection", "aria-controls": "panel-connection", type: "button" }, "This Connection");

  const panelPanorama = el("div", { class: "stack", role: "tabpanel", id: "panel-panorama", "aria-labelledby": "tab-panorama" }, panorama);
  const panelConnection = el("div", { class: "stack", role: "tabpanel", id: "panel-connection", "aria-labelledby": "tab-connection" }, connection);

  function select(which: "panorama" | "connection") {
    const onPanorama = which === "panorama";
    tabPanorama.setAttribute("aria-selected", String(onPanorama));
    tabConnection.setAttribute("aria-selected", String(!onPanorama));
    tabPanorama.tabIndex = onPanorama ? 0 : -1;
    tabConnection.tabIndex = onPanorama ? -1 : 0;
    panelPanorama.hidden = !onPanorama;
    panelConnection.hidden = onPanorama;
  }
  tabPanorama.addEventListener("click", () => select("panorama"));
  tabConnection.addEventListener("click", () => select("connection"));
  const tablist = el("div", { class: "tabs", role: "tablist", "aria-label": "MCP Glimpse views" }, tabPanorama, tabConnection);
  tablist.addEventListener("keydown", (e) => {
    const ev = e as KeyboardEvent;
    if (ev.key === "ArrowRight" || ev.key === "ArrowLeft") {
      ev.preventDefault();
      const next = tabPanorama.getAttribute("aria-selected") === "true" ? "connection" : "panorama";
      select(next);
      (next === "panorama" ? tabPanorama : tabConnection).focus();
    }
  });

  const footer = el("footer", { class: "foot" },
    "Privacy — your snapshot is analyzed in memory to draw this view and is never persisted, logged, or sent anywhere. Close the panel and it's gone.");

  const shell = el("div", { class: "wrap" }, headerBlock(r), tablist, panelPanorama, panelConnection, footer);
  select(startTab);
  root().replaceChildren(shell);
}
