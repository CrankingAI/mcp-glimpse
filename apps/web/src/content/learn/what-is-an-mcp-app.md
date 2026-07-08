---
title: "What is an MCP App (ui:// / SEP-1865)?"
answer: >-
  An MCP App is a small, self-contained HTML interface a server ships alongside a
  tool so its result renders as a real UI — a rectangle in the host — instead of
  plain text. The server publishes the interface as a ui:// resource and links a
  tool to it via _meta, and the host renders it in a locked-down iframe. It's the
  proposal tracked as SEP-1865, and the security model is the interesting part:
  the iframe makes no external requests.
description: >-
  What an MCP App (the ui:// interface proposal, SEP-1865) is, how a tool links to
  its view, and why the rendering iframe is deliberately locked down.
pubDate: 2026-07-04
order: 8
tags: ["mcp", "mcp-apps", "ui", "sep-1865"]
faqs:
  - question: "What is an MCP App?"
    answer: >-
      An MCP App is a self-contained HTML view a server publishes as a ui://
      resource and links to a tool, so the tool's result renders as an interactive
      UI inside the host rather than as plain text. It's the interface proposal
      tracked as SEP-1865.
  - question: "How does a tool link to its MCP App view?"
    answer: >-
      The tool references the view's resource URI through its _meta (for example a
      _meta.ui.resourceUri pointing at the ui:// resource), and marks the resource
      with an HTML content type profiled for MCP apps. The host reads that link and
      renders the view when the tool returns.
  - question: "Is an MCP App view sandboxed?"
    answer: >-
      Yes. The host renders it in a locked-down iframe with a strict content
      policy that blocks external network requests, so the view must be entirely
      self-contained. Never inject tool data with innerHTML — that would open an
      XSS hole inside the sandbox.
---

Most MCP tools return text. That's fine for a lot of things, but a report — a
table of servers, a capability matrix, a token-cost breakdown — wants to be
*looked at*, not read as a wall of JSON. **MCP Apps** are the answer: a server can
ship a small interface that the host renders as a genuine UI rectangle when a tool
returns. The proposal is tracked as **SEP-1865**.

## How it fits together

An MCP App has three moving parts:

1. **A `ui://` resource.** The server publishes the interface as a resource with a
   `ui://` URI — a self-contained HTML document — marked with an HTML content type
   profiled for MCP apps (e.g. `text/html;profile=mcp-app`).
2. **A tool that links to it.** The tool references that resource through its
   `_meta` (for example, `_meta.ui.resourceUri`), so the host knows *this tool's
   result should render in that view*. The tool can also hint at presentation,
   like `prefersBorder`.
3. **A host that renders it.** When the tool returns, the host loads the `ui://`
   document into an iframe and hands it the tool's result data to display.

The result: instead of a paragraph of text, the user sees a rendered rectangle —
[mcp-glimpse](/)'s two-tab report of the agent's whole context is exactly this.

## The security model — a locked-down iframe

The most important thing to understand about MCP Apps is the sandbox. The host
renders the view in an **iframe with a strict Content-Security-Policy that blocks
external network requests**. The view cannot phone home, load a remote script,
fetch a tracker, or exfiltrate the data it's showing. Everything it needs must be
**inlined** — one self-contained HTML file, no runtime external requests.

That constraint shapes how you build the view:

- **Self-contained by construction.** Bundle CSS, JS, and assets into the single
  file. A common toolchain is Vite with a single-file plugin, producing one HTML
  document with no external references.
- **Never `innerHTML` on tool data.** The tool's result is data, and rendering it
  with `innerHTML` would open a cross-site-scripting hole *inside* the sandbox. Set
  text with safe DOM APIs instead.

## A useful side effect: sharing must be deliberate

Because the iframe can't make external requests, an MCP App **cannot** silently
upload anything — which is great for privacy but means a "share this" feature can't
just POST from the view. It has to round-trip through the server via an explicit
tool call. That constraint conveniently forces a consent moment: the user has to
approve the share (often confirmed by [elicitation](/learn/server-to-client-capabilities))
before anything leaves the sandbox. The security limitation becomes a feature.

To see a real MCP App, connect mcp-glimpse and run `introspect_mcp_context` in a
host that supports MCP Apps — the report renders as a live rectangle. In a host
that doesn't, the same tool degrades to readable text, so nothing is lost.
