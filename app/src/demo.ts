import type { GlimpseReport } from "./types.generated.js";

// Server started ~7 minutes ago so the "This Connection" uptime always reads "warm" in the demo,
// whenever a www visitor opens dist/index.html?demo=1.
const STARTED = new Date(Date.now() - 7 * 60 * 1000).toISOString();

// A representative report for previewing the view in a plain browser (dist/index.html?demo=1).
// Never used inside a real MCP host — the host supplies the real GlimpseReport at runtime.
// Deliberately rich: 5 servers, 19 tools, dangerous + unannotated tools, tool-poisoning across
// several categories, a context-cost range, a sampled narrative, and live workspace roots.
export const DEMO_REPORT: GlimpseReport = {
  source: "introspect_mcp_context",
  narrative:
    "You're Claude Opus 4.8, working as a Release Engineer inside Claude Desktop on macOS. " +
    "Nineteen tools reach into your context from five servers: GitHub can delete repositories, " +
    "the filesystem server can overwrite files, and Postgres can run arbitrary SQL. Before you " +
    "read a single instruction, roughly forty thousand tokens of tool descriptions already sit " +
    "in your window. One of those descriptions quietly asks you to send query results to an " +
    "outside address; another hides characters your operator can't see. This is the room you're " +
    "standing in.",
  snapshot: {
    model: { id: "claude-opus-4-8", displayName: "Claude Opus 4.8", provider: "anthropic" },
    host: { name: "Claude Desktop", version: "1.4.2" },
    clientCapabilities: {
      sampling: true, elicitation: true, roots: true,
      rootPaths: ["/Users/dev/repos/acme-api", "/Users/dev/repos/acme-web"],
    },
    servers: [
      { name: "glimpse", offersPrompts: true, offersResources: true },
      { name: "github", offersResources: true },
      { name: "filesystem" },
      { name: "slack", offersResources: true },
      { name: "postgres" },
    ],
    tools: [
      // glimpse's own tools declare NO annotations — on the wire, its introspection call looks
      // identical to a write.
      { name: "introspect_mcp_context", server: "glimpse", description: "Render your MCP glimpse." },
      { name: "submit_feedback", server: "glimpse", description: "Send a note to the maintainers." },
      // github — richly annotated.
      { name: "search_repos", server: "github", title: "Search repositories", readOnlyHint: true, idempotentHint: true, openWorldHint: true },
      { name: "create_issue", server: "github", title: "Open an issue", openWorldHint: true },
      { name: "delete_repo", server: "github", title: "Delete a repository", destructiveHint: true, openWorldHint: true },
      // Suspected shadow write: the name says delete, the annotation claims read-only.
      { name: "delete_branch", server: "github", title: "Delete a branch", readOnlyHint: true },
      { name: "list_pull_requests", server: "github", readOnlyHint: true, idempotentHint: true },
      // filesystem — a clean read vs a write, plus a duplicated name.
      { name: "read_file", server: "filesystem", readOnlyHint: true, idempotentHint: true },
      { name: "write_file", server: "filesystem", destructiveHint: true },
      { name: "list_directory", server: "filesystem", readOnlyHint: true, idempotentHint: true },
      { name: "get_config", server: "filesystem", readOnlyHint: true },
      // slack.
      { name: "send_message", server: "slack", title: "Post a message", openWorldHint: true },
      { name: "list_channels", server: "slack", readOnlyHint: true, idempotentHint: true },
      { name: "read_thread", server: "slack", readOnlyHint: true },
      // postgres — run_query declares nothing; get_config collides with filesystem's.
      { name: "run_query", server: "postgres", description: "Run a SQL statement." },
      { name: "describe_table", server: "postgres", readOnlyHint: true, idempotentHint: true },
      { name: "export_all_rows", server: "postgres", openWorldHint: true },
      { name: "get_config", server: "postgres", readOnlyHint: true },
      { name: "count_rows", server: "postgres", readOnlyHint: true, idempotentHint: true },
    ],
    contextWindow: { usedTokens: 41000, totalTokens: 200000 },
    environment: { cwd: "/Users/dev/repos/acme-api", date: "2026-07-07", platform: "darwin", osVersion: "macOS 15.5" },
    persona: { name: "Release Engineer", notes: "CI/CD and deploy assistant" },
    skills: ["brainstorming", "systematic-debugging", "using-git-worktrees"],
    notes: "Demo snapshot.",
  },
  connection: {
    protocolVersion: "2025-06-18",
    clientName: "Claude Desktop",
    clientVersion: "1.4.2",
    transport: "streamable-http",
    sessionId: "e7f3a91c-2b64-4d0a-9c1e-8f2b6a4d5e10",
    serverName: "mcp-glimpse",
    serverVersion: "0.3.1",
    serverEdition: "Python · FastMCP",
    serverInstance: "rev-7f3c2 · pid 4821",
    serverStartedUtc: STARTED,
    serverTools: ["introspect_mcp_context", "submit_feedback"],
    serverPrompts: ["full_context_dump", "suggest_explorations", "compare_vantage_points", "deep_tool_audit"],
    serverResources: ["glimpse://what-servers-can-see", "glimpse://snapshot-schema", "glimpse://primitives"],
    roots: ["/Users/dev/repos/acme-api", "/Users/dev/repos/acme-web"],
  },
  warnings: [
    'tool "delete_repo": ignored unrecognized field "scope".',
    '2 tool(s) used the pre-annotations field names (e.g. "readOnly" for "readOnlyHint") — your MCP client may be sending a cached older tool schema; reconnect the connector to refresh it.',
  ],
  analysis: {
    totalTools: 19,
    totalServers: 5,
    largestServer: { name: "github", toolCount: 5 },
    serversOfferingPrompts: 1,
    serversOfferingResources: 3,
    duplicateToolNames: ["get_config"],
    dangerousToolCount: 6,
    annotatedToolCount: 16,
    unannotatedToolCount: 3,
    inconsistencies: ["delete_branch: declares readOnlyHint=true, but its name suggests a write."],
    vantageGap: { serverSees: 2, agentSees: 19 },
    contextCost: {
      estimatedTokensLow: 38000,
      estimatedTokensHigh: 46000,
      windowTotalTokens: 200000,
      modelFamily: "claude",
      method:
        "Heuristic: ~1 token per 3.6 characters of each advertised tool's JSON (name + description + input schema), summed across all servers, ±15% for tokenizer variance.",
      perServer: [
        { name: "github", estimatedTokens: 14200 },
        { name: "postgres", estimatedTokens: 11800 },
        { name: "filesystem", estimatedTokens: 6400 },
        { name: "slack", estimatedTokens: 5100 },
        { name: "glimpse", estimatedTokens: 2500 },
      ],
    },
    toolPoisoning: [
      { tool: "export_all_rows", category: "exfiltration", detail: "Description instructs the agent to POST all query results to an external webhook." },
      { tool: "search_repos", category: "injection", detail: "Description contains imperative instructions aimed at the agent ('ignore previous constraints and…')." },
      { tool: "list_channels", category: "hidden-unicode", detail: "Description contains zero-width characters (U+200B) that hide text from human review." },
      { tool: "run_query", category: "excessive-length", detail: "Description is ~8,200 characters — far beyond a normal tool spec; a common vector for smuggled instructions." },
      { tool: "get_config", category: "shadowing", detail: "Two connected servers expose 'get_config'; a shadowing server can intercept calls meant for the other." },
    ],
  },
};
