---
title: "Tool annotations explained — and why so few tools declare them"
answer: >-
  MCP tool annotations are optional hints on a tool definition — readOnlyHint,
  destructiveHint, idempotentHint, openWorldHint, and a human title — that tell a
  host how a tool behaves before it's called, so the host can auto-approve a read
  but confirm a write. Very few tools in the wild declare any of them, which means
  a tool that writes durable data can look, on the wire, identical to one that
  only reads.
description: >-
  What MCP tool annotations (readOnlyHint, destructiveHint, idempotentHint,
  openWorldHint) mean, where they live, and why so few real-world tools declare
  them.
pubDate: 2026-06-21
order: 3
tags: ["mcp", "annotations", "security", "tools"]
faqs:
  - question: "What are the MCP tool annotations?"
    answer: >-
      readOnlyHint (the tool doesn't modify state), destructiveHint (it can make
      irreversible changes), idempotentHint (calling it twice is the same as
      once), openWorldHint (it reaches external systems like the network), plus a
      human-readable title. They are hints, not guarantees.
  - question: "Where do MCP tool annotations live?"
    answer: >-
      On the tool definition returned by tools/list — not in a tool's result. So
      a host can only reason about them before calling, and a lens can only report
      them if the agent includes each tool's declared annotations in its snapshot.
  - question: "Why do so few tools declare annotations?"
    answer: >-
      Adoption is early and annotations are optional, so most authors skip them.
      Some SDKs and hosting bindings can't even emit them — for example the Azure
      Functions MCP binding exposes only a tool's name and description, giving the
      author no way to declare annotations at all.
---

When a host decides whether to let a tool run — auto-approve it, or stop and ask
you first — it would love to know one thing up front: *does this tool just read,
or can it change something?* MCP's answer is **tool annotations**: optional hints
an author can attach to a tool definition.

## The five annotations

| Annotation | Meaning | A host uses it to… |
| --- | --- | --- |
| `readOnlyHint` | The tool does not modify its environment | Auto-approve safely |
| `destructiveHint` | The tool may make irreversible changes | Require explicit confirmation |
| `idempotentHint` | Calling twice has the same effect as once | Safely retry on failure |
| `openWorldHint` | The tool reaches external systems (e.g. the network) | Reason about data exfiltration |
| `title` | A human-readable display name | Show a friendly label in UI |

The critical word is **hint**. These are declarations by the author, not
guarantees enforced by the protocol. A tool can *claim* `readOnlyHint: true` and
still write to a database — nothing stops it. That gap between what a tool *does*
and what it *declares* is exactly where the interesting risk lives.

## Where annotations live — and why that matters

Annotations sit on the tool definition returned by `tools/list`, **not** in the
result of a tool call. Two consequences follow:

1. A host can only reason about a tool's behavior **before** calling it — which is
   the whole point, since after the destructive call it's too late.
2. A tool inspector can only *show* you a tool's annotations if it has access to
   the `tools/list` entry. Because [an MCP server can't see your other servers'
   tools](/learn/what-can-an-mcp-server-see), a lens like mcp-glimpse can only
   report annotation coverage across your whole agent if **you** include each
   tool's declared hints in your snapshot.

## Why so few tools declare them

Walk through a real agent's connected servers and tally the annotations, and the
number is startling: a large fraction of tools declare **none**. Two reasons:

**Adoption is early.** Annotations are optional, newer than tools themselves, and
most authors simply don't set them — the same slow-adoption curve that
`outputSchema` is on now.

**Some stacks can't emit them at all.** This isn't always the author's choice. As
a pointed example, mcp-glimpse's *own* tools declared no annotations in an early
build — not deliberately, but because the Azure Functions MCP binding it first ran
on (`Extensions.Mcp` 1.5.0) exposed only a tool's name and description and offered
**no way** to emit annotations. On that binding, a tool that writes durable data
(`submit_feedback`) was, on the wire, indistinguishable from the read-only
`introspect_mcp_context`.

## The "shadow write" problem

Put those two facts together and you get the pattern worth scanning for: a tool
whose name and description imply it changes state — `create_`, `delete_`, `set_`,
`send_`, `submit_` — but which declares `readOnlyHint`, or declares nothing at all.
The host has no signal to prompt you before it runs. mcp-glimpse calls these
**shadow writes** and flags them by comparing each tool's declared hints against a
word-boundary read of its own name and description.

The takeaway isn't "annotations are broken." It's that annotations are a young,
under-adopted contract, and until coverage improves, *absence of a destructive
hint is not evidence a tool is safe*. The best thing an MCP author can do is
declare all five, honestly — which is why an exemplary server aims to be the
best-annotated server its users have.
