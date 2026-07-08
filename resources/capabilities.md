# MCP capability negotiation

At `initialize`, client and server each advertise capabilities; each side only uses what the
other supports.

| Capability | Advertised by | Meaning |
| --- | --- | --- |
| `tools` | server | exposes callable tools (with `listChanged`?) |
| `prompts` | server | exposes prompt templates |
| `resources` | server | exposes readable resources (with `subscribe`/`listChanged`?) |
| `sampling` | client | server may ask the client's model to generate |
| `elicitation` | client | server may prompt the user mid-call |
| `roots` | client | client advertises workspace roots |

mcp-glimpse advertises `tools`, `prompts`, `resources`. The rectangle's capability matrix lights
each one your snapshot reports across your servers.
