---
title: "How big is your context window — and what do 178 tool definitions cost?"
answer: >-
  Your context window is the total number of tokens your model can hold at once —
  often 200K for a current frontier model. Every connected tool spends part of it
  before you type a word: each tool's name, description, and input schema are
  serialized into the model's context. A heavily-connected agent with ~178 tools
  can burn roughly 30–45K tokens — 15–25% of a 200K window — purely on tool
  definitions.
description: >-
  Your context window is a fixed token budget, and connected tool definitions
  consume it before you say a word. How to estimate that cost — honestly — and why
  the number is bigger than you think.
pubDate: 2026-06-30
order: 6
tags: ["mcp", "context-window", "tokens", "cost"]
faqs:
  - question: "What is a context window?"
    answer: >-
      The context window is the maximum number of tokens a model can process in a
      single request — its working memory. Everything the model reasons over
      (system prompt, tool definitions, conversation, documents) has to fit inside
      it. A common current size is around 200K tokens.
  - question: "How much of my context window do tool definitions consume?"
    answer: >-
      Each tool contributes its name, description, and JSON input schema, which
      the host serializes into the model's context. Summed across a heavily
      connected agent — say 178 tools — that can be roughly 30–45K tokens, or
      15–25% of a 200K window, spent before the first user message.
  - question: "Does prompt caching make tool definitions free?"
    answer: >-
      No. Caching reduces the latency and dollar cost of re-sending unchanged
      tokens, but those tokens still occupy space in the context window. Occupancy
      is real whether or not the request was cache-hit.
---

Your **context window** is the model's working memory: the maximum number of
tokens it can hold and reason over in a single request. Everything — the system
prompt, your messages, retrieved documents, and every connected tool's definition
— has to fit inside it. A current frontier model commonly has a window around
**200K tokens**. Big, but finite.

Here's the part that surprises people: **a large chunk of that window can be gone
before you say a word.**

## Where the tokens go

When a host connects an MCP server, it takes each tool's definition — the **name**,
the **description**, and the **JSON-Schema for its input** — and serializes all of
it into the model's context so the model knows the tool exists and how to call it.
That's not free. A single richly-documented tool with a nested input schema can
easily be a few hundred tokens. Multiply by the number of connected tools and the
bill adds up fast.

> A heavily-connected agent with ~178 tools can spend roughly **30–45K tokens** —
> **15–25%** of a 200K window — purely on tool definitions, before the first user
> message.

That's the headline mcp-glimpse renders: *"your 178 tools consume ~40K of your
200K before you say a word."* It's computable from the snapshot alone, because the
snapshot already contains every tool's name, description, and schema.

## How to estimate it — honestly

Token counting is approximate, and being honest about *how* approximate is part of
doing it right.

- **Tokenizers differ by model family.** Claude, tiktoken (OpenAI), and
  SentencePiece (many open models) split text differently — but on prose and JSON
  the spread is roughly **±10–25%**, not orders of magnitude. A sound estimator
  uses one computational base (e.g. tiktoken's `o200k_base`, which is cheap and
  pure-Python) and applies a per-family correction, then shows the result as a
  **range** ("~38–46K") with a method footnote — never a false-precision single
  number.
- **Hosts reformat definitions before the model sees them.** The host wraps tool
  definitions in its *own* prompt syntax, so any estimate is approximate
  regardless of tokenizer. State that caveat rather than hide it.
- **Caching reduces cost, not occupancy.** Prompt caching makes re-sending
  unchanged tokens cheaper and faster — but those tokens still **occupy** window
  space. A cache hit doesn't give you the room back.

## Why the number matters

Every token spent on a tool you never call is a token unavailable for the actual
task — the document you're analyzing, the conversation history, the reasoning room
the model needs. Context-cost accounting turns "I connected a lot of servers" into
a concrete, per-server number you can act on: prune the servers you don't use, and
you get real window back.

To see your own figure, connect mcp-glimpse and run `introspect_mcp_context` with
your full inventory. It renders a headline tile — total estimated cost against your
window — plus a per-server breakdown, so you can see exactly which connectors are
the expensive ones. For how that fits into the whole report, see [Reading an
introspection report](/learn/reading-an-introspection-report).
