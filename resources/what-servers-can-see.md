# What an MCP server can (and cannot) see

A server has a **narrow** vantage point:

- **It CAN see:** its own tools/prompts/resources; the negotiated protocol version and the
  client's declared `clientInfo`/capabilities *at initialize* (when the host surfaces them);
  the transport; per-request arguments and session id.
- **It CANNOT see:** the host's **other** connected MCP servers, **their** tools, your model's
  identity, your context-window budget, your working directory, the date, your persona, or your
  active skills. None of that is in the protocol a server receives.

That panoramic view belongs to **you, the agent**. This is why `introspect_mcp_context` takes a
`snapshot_json` you fill in: you are the only party who can see the whole board. Calling `introspect_mcp_context`
with no snapshot shows the server-only slice for contrast — often just a handful of things next to your hundreds.

## Tool annotations — and a limitation of this very server

Each tool a server publishes can carry **annotations**: `readOnlyHint`, `destructiveHint`,
`idempotentHint`, `openWorldHint`, and a `title`. Hosts read them to reason about a tool before
calling it (for example, to auto-approve a read but prompt before a write). They live on the tool
definition in `tools/list`, not in a tool's result — so the lens can only show them if *you* report
each tool's declared annotations in your snapshot. When you do, the rectangle surfaces the coverage
and flags the tools that declare none.

A pointed example lives right here: **mcp-glimpse's own tools declare no annotations at all.**
Not by choice — the Azure Functions MCP binding this server runs on (`Extensions.Mcp` 1.5.0)
exposes only a tool's name and description and provides no way to emit annotations. So a tool that
writes durable data (`submit_feedback`) is, on the wire, indistinguishable from the read-only
`introspect_mcp_context` called with no snapshot. That gap between *what a tool does* and *what it declares* is exactly the kind
of minutiae this lens exists to make visible — including about itself.
