---
title: "Elicitation, sampling, and roots: MCP's server→client capabilities"
answer: >-
  Most MCP primitives flow from client to server, but three flow the other way.
  Elicitation lets a server pause a tool call to ask the user for input. Sampling
  lets a server ask the client's model to generate text. Roots let the client
  advertise its workspace folders to the server. All three require an interactive,
  stateful session and are advertised by the client at initialize — a stateless
  HTTP server cannot use them.
description: >-
  How MCP's server-to-client capabilities work — elicitation, sampling, and roots
  — what each enables, and why they require a stateful session.
pubDate: 2026-06-24
order: 4
tags: ["mcp", "capabilities", "elicitation", "sampling", "roots"]
faqs:
  - question: "What is elicitation in MCP?"
    answer: >-
      Elicitation is a server asking the user for input in the middle of a tool
      call — for example, confirming an action or collecting a missing parameter.
      It requires an interactive, stateful session and is only available when the
      client advertises the elicitation capability.
  - question: "What is sampling in MCP?"
    answer: >-
      Sampling is a server asking the client's model to generate a completion. It
      lets a server use the model's intelligence without shipping its own, but
      requires the client to advertise the sampling capability and to be in a
      stateful session.
  - question: "What are roots in MCP?"
    answer: >-
      Roots are filesystem or workspace folders the client advertises to the
      server, telling the server which directories are in scope. The client
      declares the roots capability and the server can call roots/list to read
      them.
---

The primitives most people learn first — [tools, prompts, and
resources](/learn/what-is-mcp) — all flow from the client to the server: the agent
calls a tool, reads a resource, picks a prompt. But MCP also defines three
capabilities that flow the **other** direction, from server to client. They're the
ones that make an MCP session feel genuinely interactive rather than
request/response.

## Capability negotiation, briefly

At `initialize`, the client and server each advertise what they support, and each
side uses only what the other offers. Servers advertise `tools`, `prompts`, and
`resources`. **Clients** advertise the three below. If your client doesn't
advertise `sampling`, no server can sample from your model — the capability simply
isn't there to use.

| Capability | Advertised by | Meaning |
| --- | --- | --- |
| `sampling` | client | Server may ask the client's model to generate |
| `elicitation` | client | Server may prompt the user mid-call |
| `roots` | client | Client advertises its workspace roots |

## Elicitation — the server asks the user

Elicitation lets a server **pause a tool call** and ask the user for input:
confirm a destructive action, fill in a missing parameter, choose among options.
The server sends a structured request; the host renders a prompt; the answer flows
back and the tool call resumes.

This is how a well-behaved write tool earns trust. mcp-glimpse's `submit_feedback`,
for instance, elicits a confirmation before it persists anything — and when the
client doesn't support elicitation, it degrades gracefully: it records the
feedback and labels it "unconfirmed" rather than failing.

## Sampling — the server asks your model

Sampling inverts the usual arrangement: the **server** asks the **client's model**
to generate a completion. The server ships no model of its own; it borrows the
one the user already trusts and pays for. A server might use sampling to summarize
a large result into a sentence, or to turn structured data into prose.

Sampling is powerful and therefore gated: the client must advertise the capability,
the user's host mediates every request, and it only works in a stateful session.

## Roots — the client shares its workspace

Roots are the filesystem or workspace folders the client advertises to the server,
scoping "which directories are you allowed to think about." The client declares
the `roots` capability and the server calls `roots/list` to read them — for
example, a code tool learning which repositories are open.

## Why all three need a stateful session

Elicitation, sampling, and roots each require a **back-and-forth mid-operation**: a
server issues a request and waits for the client to respond while a tool call is
still in flight. That's only possible when the session persists across messages.

A **stateless** HTTP server — one that treats every request independently and
keeps no session — structurally can't do it. It can *report* that these
capabilities were negotiated, but it can't *use* them. This is the single biggest
practical reason to choose a stateful transport, covered in [Stateless vs stateful
MCP transports](/learn/stateless-vs-stateful-transports). mcp-glimpse uses the
core three primitives to teach these three, and demonstrates elicitation, sampling,
and roots live so you can see the difference rather than take it on faith.
