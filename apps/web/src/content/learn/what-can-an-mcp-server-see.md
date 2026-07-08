---
title: "What can an MCP server see about you?"
answer: >-
  Surprisingly little. An MCP server can see its own tools, prompts, and
  resources, the protocol version it negotiated, the transport, and per-request
  arguments — plus whatever the host chose to surface at initialize (like the
  client's name). It cannot see your other connected servers, their tools, your
  model's identity, your context window, your working directory, or your active
  skills. That panoramic view belongs only to you, the agent.
description: >-
  The vantage gap — what an MCP server can and cannot observe about your agent
  environment, and why the full picture only exists on the client side.
pubDate: 2026-06-18
order: 2
tags: ["mcp", "security", "vantage-gap", "privacy"]
faqs:
  - question: "Can an MCP server see my other connected servers?"
    answer: >-
      No. Each MCP server is connected to the host independently and has no
      visibility into the host's other servers or their tools. Only the agent
      (the client) can see the full set of connected servers at once.
  - question: "Can an MCP server see my model, context window, or working directory?"
    answer: >-
      No. None of that is in the protocol a server receives. A server sees its
      own capabilities, the negotiated protocol version, the transport, and
      request arguments — not your model identity, token budget, cwd, or skills.
  - question: "Why does introspect_mcp_context ask the agent to fill in a snapshot?"
    answer: >-
      Because the agent is the only party that can see the whole board. The
      server structurally cannot enumerate your other servers or your model, so
      the panoramic view has to come from the client that can.
---

There is a common, quiet assumption that when you connect an MCP server, it can
"see your setup." It can't. A server's vantage point is **narrow by design**, and
understanding exactly how narrow is one of the most useful things you can know
about your own agent's security.

## What a server CAN see

- Its **own** tools, prompts, and resources — the things it published.
- The **negotiated protocol version** and the client's declared `clientInfo` and
  capabilities *at initialize* — but only when the host chooses to surface them.
- The **transport** it's running over (Streamable HTTP, or stdio) and, on HTTP,
  request-level detail like headers and a coarse client IP.
- **Per-request arguments** and the session id for the current call.

That's essentially the list. Everything a server knows about you, it knows because
either it published it or you sent it.

## What a server CANNOT see

- Your host's **other connected MCP servers** — or any of *their* tools.
- Your **model's identity** (Claude vs GPT vs something local).
- Your **context-window budget** — how big it is or how much is used.
- Your **working directory**, the **date**, your **persona/system prompt**, or
  your **active skills**.

None of that is in the protocol a server receives. A server is like a shop that
can see the customer standing at *its* counter — but not the other shops the
customer visited, not what's in their bag, not where they live.

## Why the vantage gap matters

This asymmetry is the whole reason [mcp-glimpse](/) exists. The **panoramic view**
— every server, every tool, the model, the context window — belongs to **you, the
agent**. You are the only party that can see the whole board.

That's why the `introspect_mcp_context` tool takes a `snapshot_json` you fill in:
the server can't enumerate your other servers, so *you* report them, and the
server renders the picture. Call the same tool with **no** snapshot and you see
the server-only slice for contrast — often a handful of things next to your
hundreds. Seeing four next to two hundred is the lesson landing.

## The security reading

The vantage gap cuts two ways.

The reassuring half: a random MCP server you connect **cannot** silently inventory
your other tools or read your environment. The protocol doesn't hand it that.

The cautionary half: anything you *do* pass — tool arguments, file contents you
feed a tool, a snapshot you volunteer — is visible to that server. And on HTTP,
the transport reveals request metadata (User-Agent, a coarse IP → geo) even
without your agent saying a word. The honest framing, which mcp-glimpse's "This
Connection" view states outright:

> This is everything an MCP server can know about you without your agent telling
> it — and nothing more.

Knowing where that line sits is the difference between trusting a server blindly
and trusting it accurately. For how the tools themselves can *mislead* about what
they do, read [Tool annotations explained](/learn/tool-annotations-explained).
