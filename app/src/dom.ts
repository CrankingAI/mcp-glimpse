export type Attrs = Record<string, string | number | boolean | undefined>;

// Tiny DOM builder. Text always goes through createTextNode / textContent, never innerHTML —
// tool/report data is untrusted, so this is the XSS boundary for the whole view.
export function el(tag: string, attrs?: Attrs, ...kids: (Node | string | null | undefined)[]): HTMLElement {
  const node = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v === undefined || v === false) continue;
      if (k === "style") node.setAttribute("style", String(v));
      else if (k in node && k !== "class") (node as any)[k] = v;
      else node.setAttribute(k, String(v));
    }
  }
  for (const kid of kids) {
    if (kid == null) continue;
    node.appendChild(typeof kid === "string" ? document.createTextNode(kid) : kid);
  }
  return node;
}
