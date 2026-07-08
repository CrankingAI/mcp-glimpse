---
title: "What is MCP? Tools vs prompts vs resources"
answer: >-
  MCP (the Model Context Protocol) is an open standard that lets an AI agent
  connect to external servers and use what they expose. A server can expose three
  core primitives: tools (functions the model calls), prompts (templates a person
  selects), and resources (readable content the app loads). The difference is
  who's in control — the model, the user, or the application.
description: >-
  A plain-English guide to the Model Context Protocol and its three core
  primitives — tools, prompts, and resources — and the control model that
  separates them.
pubDate: 2026-06-16
order: 1
tags: ["mcp", "primitives", "fundamentals"]
faqs:
  - question: "What are the three MCP primitives?"
    answer: >-
      Tools (model-invoked functions), prompts (user-selected message
      templates), and resources (application-loaded readable content). Later
      revisions add server-to-client capabilities — sampling, elicitation, and
      roots — but tools, prompts, and resources are the core three.
  - question: "What is the difference between an MCP tool and an MCP resource?"
    answer: >-
      A tool is a function the model decides to call, with a JSON-Schema input
      and a returned result. A resource is addressable content published at a URI
      that the client application reads for context — it isn't called, it's read.
  - question: "Who controls each MCP primitive?"
    answer: >-
      Tools are model-controlled (the model chooses when to call them), prompts
      are user-controlled (a person picks one), and resources are
      application-controlled (the client reads them to build context).
---

The Model Context Protocol (MCP) is an open standard — originally from Anthropic,
now with a broad implementer community — for connecting AI agents to external
capabilities. Instead of every tool integration being a bespoke plugin, MCP
defines a common wire protocol: an agent's **host** (Claude Desktop, an IDE, a
custom agent) speaks to one or more **MCP servers**, each of which advertises
what it can do.

The word that trips people up is "server." An MCP server is usually a small local
process or a remote HTTP endpoint that publishes a handful of capabilities. It is
not a monolith. A well-designed agent might have a dozen of them connected at
once — one for your files, one for a database, one for GitHub, one that
introspects the agent itself (that's what [mcp-glimpse](/) does).

## The three core primitives

Every MCP server can expose up to three kinds of things. What separates them is
**who decides when they're used**.

| Primitive | Controlled by | What it is | Example |
| --- | --- | --- | --- |
| **Tools** | the model | Functions the model can invoke, each with a JSON-Schema input | `introspect_mcp_context` |
| **Prompts** | the user | Parameterized message templates a person selects | `full_context_dump` |
| **Resources** | the application | Readable content published at a URI | `glimpse://primitives` |

### Tools — model-invoked functions

A tool is a function the server exposes and the model chooses to call. Each tool
carries a name, a description, and a JSON-Schema for its input. When the model
decides a tool is relevant, the host sends a `tools/call` request; the server runs
it and returns a result. Tools are the primitive most people mean when they say
"MCP" — they're how an agent takes action in the world.

Because the model reads the name and description to decide *whether* to call a
tool, those strings are part of the contract. Rename a tool and every agent that
learned to call it breaks.

### Prompts — user-selected templates

A prompt is a reusable, parameterized message template the server offers for a
**person** to pick — think of the slash-command menu in a chat client. The user
selects it; it isn't auto-invoked by the model. Prompts are how a server ships
expert phrasing: instead of hoping the model asks the right question, the server
hands the user a ready-made one.

### Resources — application-loaded content

A resource is addressable, readable content published at a URI like
`glimpse://primitives`. The client **application** reads it to build context —
resources aren't "called," they're loaded, the way a program reads a file. They're
ideal for reference material, schemas, and documentation the agent may want in
context without spending a tool call to fetch it.

## Beyond the core three

Later protocol revisions added a second class of primitives that flow the *other*
direction — from server to client. **Sampling** lets a server ask the client's
model to generate text; **elicitation** lets a server prompt the user for input
mid-call; **roots** let the client advertise workspace folders to the server.
These require an interactive, stateful session and are covered in
[Elicitation, sampling, and roots](/learn/server-to-client-capabilities).

mcp-glimpse itself uses the first three primitives to teach the rest: a single
tool (`introspect_mcp_context`), a set of prompts, and a small library of
`glimpse://` resources that explain the very concepts on this page.
