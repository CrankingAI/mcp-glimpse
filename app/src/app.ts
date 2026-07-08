import { App } from "@modelcontextprotocol/ext-apps";
import { el } from "./dom.js";
import { render } from "./render.js";
import { DEMO_REPORT } from "./demo.js";
import type { GlimpseReport } from "./types.generated.js";

const root = () => document.getElementById("root")!;

// A calm placeholder that matches the Paper & Proof shell (waiting / error states).
function stateCard(title: string, body: string): HTMLElement {
  return el("div", { class: "wrap" },
    el("div", { class: "state" },
      el("div", { class: "eyebrow" }, "MCP Glimpse"),
      el("h2", {}, title),
      el("p", { class: "hint" }, body)));
}

// Some MCP clients serialize with PascalCase keys (.NET/JSON.NET style). The wire type is
// camelCase, so we first-letter-lowercase every key recursively; for already-camelCase payloads
// this is a harmless no-op, and it lets a PascalCase host survive without a schema mismatch.
function lowerKeys(v: any): any {
  if (Array.isArray(v)) return v.map(lowerKeys);
  if (v && typeof v === "object") {
    const o: any = {};
    for (const k of Object.keys(v)) o[k.charAt(0).toLowerCase() + k.slice(1)] = lowerKeys(v[k]);
    return o;
  }
  return v;
}

function parseToolResult(content: Array<{ type: string; text?: string }> | undefined): GlimpseReport | null {
  const block = content?.find((c) => c.type === "text" && c.text);
  if (!block?.text) return null;
  try { return lowerKeys(JSON.parse(block.text)) as GlimpseReport; }
  catch (e) { console.error("Failed to parse GlimpseReport", e); return null; }
}

function applyTheme(theme?: string) {
  if (theme === "light" || theme === "dark") document.documentElement.dataset.theme = theme;
}

async function main() {
  // dist/index.html?demo=1 renders a rich fixture so a www visitor sees the rectangle
  // populated before ever connecting to a host.
  if (new URLSearchParams(location.search).get("demo")) {
    render(DEMO_REPORT);
    return;
  }
  root().replaceChildren(stateCard("Waiting for context…", "Call introspect_mcp_context to render your MCP glimpse here."));

  const app = new App({ name: "MCP Glimpse", version: "0.1.0" });
  app.ontoolresult = (params) => {
    const report = parseToolResult(params.content as Array<{ type: string; text?: string }>);
    if (report) render(report);
    else root().replaceChildren(stateCard("Couldn't read the result", "The tool result was not in the expected GlimpseReport format."));
  };
  app.onhostcontextchanged = (ctx: any) => applyTheme(ctx?.theme);

  await app.connect();
  applyTheme(app.getHostContext()?.theme);
}

main().catch((e) => {
  console.error(e);
  root().replaceChildren(stateCard("Failed to start", String(e)));
});
