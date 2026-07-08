---
title: "Stateless vs stateful MCP transports (what each can and cannot do)"
answer: >-
  A stateful MCP transport keeps a session alive across messages, so the server
  can hold context, push notifications, and do mid-call back-and-forth like
  elicitation, sampling, and roots. A stateless transport treats every request
  independently — it's simpler and scales trivially, but it can only report those
  interactive capabilities, never use them. If you want an interactive MCP server,
  statefulness is a gate, not an option.
description: >-
  The practical difference between stateless and stateful MCP transports — what
  each enables, what breaks, and why interactive capabilities require a session.
pubDate: 2026-06-27
order: 5
tags: ["mcp", "transports", "http", "stateful", "architecture"]
faqs:
  - question: "What is the difference between a stateless and a stateful MCP server?"
    answer: >-
      A stateful server keeps a session alive across requests, enabling
      server-initiated messages and mid-call interaction (elicitation, sampling,
      roots, progress, logging). A stateless server handles each request
      independently — simpler and infinitely scalable, but unable to use those
      interactive capabilities.
  - question: "Can a stateless MCP server use elicitation or sampling?"
    answer: >-
      No. Elicitation, sampling, and roots require a mid-operation back-and-forth,
      which needs a persistent session. A stateless server can report that those
      capabilities were negotiated, but it cannot actually use them.
  - question: "Does stdio count as stateful?"
    answer: >-
      Yes. A stdio connection is a single long-lived process with an open pipe, so
      it's inherently stateful. Streamable HTTP can be run either way — stateful
      (with a session id) or stateless — which is the choice that matters.
---

"Transport" in MCP means how the client and server actually exchange bytes. There
are two common ones — **stdio** (a local process over standard input/output) and
**Streamable HTTP** (a remote endpoint) — but the distinction that changes what
your server can *do* isn't stdio-vs-HTTP. It's **stateful vs stateless**.

## What "stateful" buys you

A stateful transport keeps a **session** alive across many messages. The server
can remember what happened earlier in the conversation, push messages to the
client on its own initiative, and carry on a mid-operation exchange. That single
property unlocks a whole tier of the protocol:

- **Elicitation** — pause a tool call to ask the user a question.
- **Sampling** — ask the client's model to generate mid-call.
- **Roots** — read the client's advertised workspace folders.
- **Progress notifications** — stream "37% done" during a long operation.
- **Server-initiated logging** — emit log lines to the client as work happens.
- **`listChanged`** — tell the client the tool list changed, live.

Every one of these needs the server to speak *while a request is in flight* or
*between* requests — which requires the session to persist.

## What "stateless" gives up — and gains

A stateless transport handles each request in complete isolation. There's no
session to hold, so:

- It **cannot** use elicitation, sampling, roots, progress, or live `listChanged`.
  It can *report* that the client advertised these capabilities, but it has no
  channel to exercise them.
- In exchange, it's dramatically **simpler to operate**. Any replica can serve any
  request, so it scales horizontally without sticky sessions, and a cold start
  costs nothing in correctness.

Stateless isn't wrong — for a pure read-only tool server it's an excellent,
cheap choice. It's just a ceiling: you've capped the server at the
request/response subset of MCP.

## The mapping to real transports

| Transport | Typically | Notes |
| --- | --- | --- |
| **stdio** | Stateful | One long-lived process with an open pipe — inherently a session. |
| **Streamable HTTP** | Either | The design decision. With a session id it's stateful; without, it's stateless. |

Note the nuance: HTTP is where you actually *choose*. Streamable HTTP can be run
stateful (issuing a session id the client returns on each request, pinned to one
replica or backed by sticky sessions) or stateless (every request independent).

## Operational cost of "stateful" — verified the hard way

Choosing stateful HTTP has real deployment consequences, and they tend to surface
only in production:

- **Session affinity.** A session-bearing server needs requests to land on the
  same replica — a single replica, or sticky sessions. Round-robin across replicas
  drops the session.
- **No scale-to-zero for interactive use.** If the platform scales the server to
  zero between requests, an interactive connector-add times out on the cold start.
  Keep at least one replica warm.
- **Host allowlists.** SDKs guard against DNS-rebinding by checking the `Host`
  header; behind a public domain you must allowlist that host or every request
  returns a 421.

## The verdict

If your server only reads, stateless is a fine, cheap default. But the moment you
want the *interactive* half of MCP — confirmations, model sampling, workspace
awareness, live progress — **statefulness is a gate, not an option.** That's
exactly why mcp-glimpse runs a stateful Streamable HTTP session: the interactive
capabilities it teaches, it also demonstrates live. See [Elicitation, sampling,
and roots](/learn/server-to-client-capabilities) for what those capabilities
actually do.
