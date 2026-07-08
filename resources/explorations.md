# Interesting things to ask the lens

Each of these is a high-signal question `mcp-glimpse` is built to answer. Pick one — ideally the
most revealing — gather what it needs, and finish by calling `introspect_mcp_context` so the answer
lands in the app rectangle.

1. **Shadow writes.** Which of your tools can change state or reach the network but declare
   `readOnlyHint` — or declare no annotations at all? Report each tool's declared hints alongside
   your own read of its real behaviour; the lens flags the mismatch. (Run `deep_tool_audit` to gather this.)
2. **The vantage gap.** Run `introspect_mcp_context` with no snapshot, then again with your full inventory.
   How many tools does a single server see versus how many *you* see? (See `glimpse://what-servers-can-see`.)
3. **Name collisions.** Do any two connected servers expose the *same* tool name? Enumerate every
   tool with its owning server so the lens can flag the duplicates.
4. **Context headroom.** Report your context-window tokens used vs total — how much budget is left,
   and how big is the window you're reasoning inside?
5. **Capability spread.** Which of your servers offer prompts and resources, not just tools? The
   capability matrix lights up what's actually in play across your whole connector set.
6. **Annotation coverage.** What fraction of your tools declare *any* MCP annotations, and which
   declare none? Unannotated write tools are the interesting ones. (Run `deep_tool_audit`.)
7. **Protocol truth.** From `introspect_mcp_context` (no snapshot) and `glimpse://protocol-versions`: which protocol
   version did you actually negotiate, and what does the server admit it cannot see about you?

Not sure where to start? **Shadow writes** and **the vantage gap** are the two that surprise
people most.
