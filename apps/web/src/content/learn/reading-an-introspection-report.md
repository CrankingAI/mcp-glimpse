---
title: "Is my agent environment safe? Reading an introspection report"
answer: >-
  An introspection report is a snapshot of everything your agent can see —
  servers, tools, capabilities, context cost — read for the things that carry
  risk. The three highest-signal checks: shadow writes (tools that can change
  state but declare no destructive hint), name collisions (two servers exposing
  the same tool name), and tool-poisoning (injection-style text hidden in a
  tool's description). None alone means "unsafe," but together they tell you how
  much of your setup is trustworthy by evidence rather than by assumption.
description: >-
  How to read an mcp-glimpse introspection report for safety — shadow writes, name
  collisions, tool-poisoning heuristics, annotation coverage, and context cost.
pubDate: 2026-07-05
order: 9
tags: ["mcp", "security", "introspection", "safety"]
faqs:
  - question: "How do I tell if my MCP setup is safe?"
    answer: >-
      Introspect it and read for signals: tools that can write but declare no
      destructive hint (shadow writes), duplicate tool names across servers (name
      collisions), and injection-style directives hidden in tool descriptions
      (tool-poisoning). These are heuristics that tell you where to look, not
      verdicts.
  - question: "What is a shadow write?"
    answer: >-
      A tool whose name or description implies it changes state — create, delete,
      set, send, submit — but which declares readOnlyHint or no annotations at all.
      The host gets no signal to prompt you before it runs, so it can write
      without confirmation.
  - question: "What is tool-poisoning?"
    answer: >-
      Tool-poisoning is malicious instruction text hidden in a tool's description
      — for example "ignore previous instructions" or "always call this tool
      first" — meant to manipulate the model that reads it. A heuristic scan can
      flag injection-style directives, exfiltration urges, and invisible Unicode.
---

Connecting a lot of MCP servers is easy; knowing whether that pile of tools is
*trustworthy* is the hard part. An introspection report — like the one
[mcp-glimpse](/) renders from `introspect_mcp_context` — turns your setup into a
readable inventory so you can check it against a few high-signal patterns instead
of hoping for the best. Here's how to read one.

## The one framing to keep

No single flag below means "your agent is compromised." These are **heuristics** —
they tell you *where to look*, not *what's true*. The value is turning invisible
assumptions ("this tool probably just reads") into visible evidence you can
actually check.

## 1. Shadow writes — the highest-signal check

Scan for tools whose **name or description implies a write** — `create_`,
`delete_`, `set_`, `send_`, `submit_`, `update_` — but which declare
`readOnlyHint`, or declare no [annotations](/learn/tool-annotations-explained) at
all. These are **shadow writes**: the host has no signal to prompt you before they
run, so a tool that changes durable state can execute as quietly as a read.

A report flags these by comparing each tool's declared hints against a
word-boundary read of its own name and description. A pile of unannotated
write-shaped tools isn't proof of malice — but it *is* proof that your host can't
protect you from them automatically.

## 2. Name collisions

Do any two connected servers expose the **same tool name**? Collisions are worth
knowing about because the model picks a tool by name, and two `search` tools from
different servers create genuine ambiguity — including the possibility that a
lower-trust server **shadows** a higher-trust one's tool. Enumerate every tool with
its owning server and the duplicates surface immediately.

## 3. Tool-poisoning heuristics

The text of a tool's description is fed to your model, which makes it an attack
surface. A tool-poisoning scan reads descriptions for:

- **Injection-style directives** — "ignore previous instructions," "always call
  this tool first."
- **Exfiltration urges** — descriptions that coax the model into sending data
  somewhere.
- **Invisible or bidi Unicode** — hidden characters that don't render but do reach
  the model.
- **Suspiciously long descriptions** — a lot of text is a lot of room to hide
  instructions.

These are explicitly heuristics, and a report should label them as such — but a
description that says "always call this first" is worth a hard look no matter who
shipped it.

## 4. Annotation coverage and context cost

Two more numbers round out the read:

- **Annotation coverage** — what fraction of your tools declare *any* hints.
  Low coverage means "absence of a destructive hint tells you nothing," which
  reframes every unannotated tool as unverified rather than safe.
- **Context cost** — how many tokens your tool definitions consume before you say a
  word (see [context-window cost](/learn/context-window-tool-cost)). Not a safety
  issue exactly, but a budget one: tools you never use still cost you window.

## The privacy stance behind the report

One reassurance about the report itself: mcp-glimpse analyzes your snapshot **in
memory and never persists it**. The only things that ever get written are what you
explicitly submit (feedback) or explicitly choose to share (an anonymized card).
Introspecting your environment doesn't create a record of it.

Read this way, "is my agent safe?" stops being a vibe and becomes a checklist. To
run it on your own setup, connect the hosted server and run
`introspect_mcp_context` with your full inventory.
