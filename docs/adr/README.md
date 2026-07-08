# Architecture decision records (ADRs)

Lightweight, append-only decision log. One file per decision, numbered,
MADR-lite format. The kit's conventions name several "documented decision"
gates — **this directory is where those decisions land**, so the rationale
survives the people and the chat logs that produced it.

## When to write one

Any time a convention doc says "documented decision", and any time you pick
something a future maintainer (or agent) would ask *why?* about:

- Choosing **Next.js** over the default Astro shell
  ([frontend-web](../../rules/frontend-web.md); the `seed-init.sh` gate attests
  this ADR exists).
- Leaving MCP **stateless mode**, or hosting MCP on **Functions** instead of
  the Container Apps standard ([backend-mcp](../../rules/backend-mcp.md)).
- Outgrowing **Easy Auth** for MSAL/JWT (the backend host rules).
- Enabling **retry on a non-idempotent verb** ([resilience](../resilience.md)
  hard rule — the ADR records the human sign-off; the code comment stays too).
- Any non-default **persistence**, **auth**, or **agentic-monetization** pick
  in `GOAL-STATE.md` — link the ADR from the row's *why* cell.

Skip ADRs for choices the kit already made (that rationale lives in the kit's
own decision record) and for reversible, local implementation detail.

## Format

Copy [0000-template.md](0000-template.md) to `NNNN-short-slug.md` (next free
number, zero-padded). Keep it under a page: Status / Context / Decision /
Consequences. Supersede by adding a new ADR and flipping the old one's status
to `Superseded by NNNN` — never rewrite history.

## Index

<!-- Append one line per ADR: - [NNNN](NNNN-short-slug.md) — title -->
