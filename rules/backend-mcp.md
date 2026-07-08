# Backend — MCP Server (.NET 10)

A **Model Context Protocol** server built with `ModelContextProtocol.AspNetCore`
(**1.3.0+**), exposing tools to AI clients over **Streamable HTTP**. Keep this rule
when the workload includes "tools an AI agent calls."

**MCP is an interface, not a host — it is orthogonal to the host choice.** It runs
as an ASP.NET Core app on **Container Apps** (the kit standard — see below). It is
**not** a mutually-exclusive peer of the host rules: keep it *alongside* your
Container Apps host rule to expose **both** a human HTTP API and an MCP tool
server, or keep it **alone** for an MCP-only service. (If the human API runs on
Functions, the MCP server is its own Container Apps service.)

**The ASP.NET Core path is a kit standard, not a platform limit.** MCP can also
be hosted on Azure Functions via the
`Microsoft.Azure.Functions.Worker.Extensions.Mcp` extension (`[McpToolTrigger]` /
`[McpToolProperty]`, exposed at `/runtime/webhooks/mcp`). The kit standardizes on
`ModelContextProtocol.AspNetCore` because (a) it validates OAuth tokens with stock
`JwtBearer` and publishes OAuth Protected Resource Metadata — the clean DCR/OAuth
story below — while the Functions extension defaults to a system-key webhook and
needs built-in auth or APIM layered on for real OAuth; and (b) it shares one
programming model (`[McpServerTool]`) with the human HTTP API, so co-hosting both
in one app stays simple. This is a preference grounded in the OAuth experience and
codebase uniformity, not an impossibility — choosing the Functions path is a
documented decision (an ADR — [docs/adr](../docs/adr/README.md)), not a default.

This file is self-contained — including its own host story — so an MCP-only repo
needs nothing from the sibling `rules/backend-*.md` files.

## Project shape

ASP.NET Core 10 host. Register the server, expose the Streamable HTTP transport in
**stateless mode**, and mount the endpoint.

```csharp
builder.Services.AddMcpServer()
    .WithHttpTransport(o => o.Stateless = true) // Streamable HTTP, stateless
    .WithToolsFromAssembly();                   // discovers [McpServerToolType] classes

var app = builder.Build();
app.MapMcp("/mcp"); // Streamable HTTP endpoint at /mcp
```

- Pin the package: `dotnet add package ModelContextProtocol.AspNetCore --version 1.3.*`.
- MCP endpoints return JSON-RPC, not health JSON — keep `/livez` `/readyz` `/version`
  **separate** from `/mcp` (see the cross-cutting contract below).
- Wire `ServiceDefaults` (OTel → App Insights, resilience, health).

## Stateless mode — the caveat (read before choosing)

Stateless mode is the default here: it scales horizontally with no sticky sessions, fits
ACA scale-out, and survives replica churn. **The trade-off is real** —
stateless disables the server→client interactive features:

- **sampling** (server asking the client's model to generate),
- **elicitation** (server prompting the user for input mid-tool-call),
- **roots** (client-advertised filesystem/workspace roots),
- **unsolicited notifications** (server-initiated pushes outside a request/response).

If a tool genuinely needs any of these, that is a documented decision (an ADR —
[docs/adr](../docs/adr/README.md)) to leave stateless mode — and it changes the hosting
story (session affinity / a backplane). Do not flip it silently.

### This is an up-front stack gate, not only a late ADR

Building the same server three ways (Functions binding, Python/FastMCP,
AspNetCore stateful) showed the stateless choice is a **first-question gate on
the whole stack** (fleet finding, [docs/backlog.md](../docs/backlog.md) §13).
**Two independent axes** decide it — one from statefulness, one from the binding:

**Statefulness (`WithHttpTransport(Stateless = false)`) — the server can speak
first.** A live bidirectional session lets the server, mid-call:

- **Elicitation / sampling / roots** — prompt the user to confirm or fill
  something, ask the client's model to generate, query the client's workspace
  roots.
- **Proactive notifications** including `notifications/tools/list_changed` —
  push an updated tool/resource/prompt list without the client polling.
- **Surface real session facts** — the negotiated `protocolVersion`,
  `clientName`/`version`, `sessionId` (Functions leaves all of these `null`).

Stateless Functions can *detect and report* client support for these but
structurally **cannot use** them.

**Binding capability (independent of statefulness) — tool annotations.** The
Functions `[McpToolTrigger]` binding emits only name + description; it **cannot
declare** `readOnlyHint` / `destructiveHint` / etc. `ModelContextProtocol`
`.AspNetCore` sets them on `[McpServerTool]`, verifiable in `tools/list`. On the
wire a Functions write tool is indistinguishable from a read, so a host cannot
auto-approve reads vs. prompt for writes. This gap would remain even if
Functions were stateful.

**Cost of stateful (the honest caveats).** A session pins to one instance, so
scaling out needs sticky sessions (the ACA MCP apps run `min = max = 1`), and
cold start breaks the connector handshake → `minReplicas >= 1`, no
scale-to-zero for interactive use. Functions keeps the edge in **stateless
simplicity + free storage** — right for a server that only ever responds to
isolated tool calls and never needs to speak first.

**Planning gate:** before writing any tool ask — *does one need a server→client
capability (elicitation / sampling / roots / `list_changed`) OR tool
annotations?* If yes → `ModelContextProtocol.AspNetCore` **stateful** on
Container Apps (the kit standard), not the Functions binding. Deciding this late
is a rewrite, not an ADR.

## Tool & parameter names ARE the public contract

Tool names and parameter names are consumed by AI clients exactly as published. **A rename
is a semver-breaking change.** Pin them explicitly — never rely on method/parameter
identifiers leaking through reflection.

- `[McpServerTool(Name = "...")]` on every tool method — the wire name is decoupled from
  the C# method name, so refactoring the method never breaks clients.
- `[Description("...")]` on the **method** AND on **every parameter** — the description is
  how the calling model understands when and how to invoke the tool. Missing param
  descriptions degrade tool selection.

```csharp
[McpServerToolType]
public sealed class DomainTools
{
    [McpServerTool(Name = "check_domain")]
    [Description("Check whether a domain name is registered and available.")]
    public async Task<DomainResult> CheckDomain(
        [Description("Fully-qualified domain name, e.g. example.com")] string domain,
        CancellationToken ct) => await _client.CheckAsync(domain, ct);
}
```

> HARD RULE: renaming a tool or a parameter (the `Name =` value or a `[Description]`-bearing
> param) is **semver-breaking**. Bump major; do not slip it into a patch.

### The contract is client-cache-persistent — warn, never silently drop

Two runtime realities compound the rename rule (fleet finding,
[docs/backlog.md](../docs/backlog.md) §13):

- **`tools/list` is cached by clients.** A field rename (`readOnly` →
  `readOnlyHint`) is broken until the client **reconnects** — it keeps sending
  the old names. Detectable: if a deprecated field name arrives, emit a
  **stale-client advisory** ("your client may have a cached older schema —
  reconnect"). **Alias-tolerant parsing** (accept old AND new names) makes a
  rename non-breaking retroactively.
- **Never silently drop unrecognized input.** For any tool taking free-form /
  JSON-string input, surface unknown fields as **warnings** — a silent drop is
  worse than an error because the output still looks trustworthy (a real case:
  dropped keys produced a confident-but-wrong "N of N tools declare no
  annotations"). Cheap sibling warnings in the same spirit:
  non-boolean-where-boolean, alias-vs-canonical conflict,
  reference-to-undeclared-entity.

A committed **contract-snapshot test** (freeze tool/prompt/resource names +
input schemas; fail CI on drift — queued, [docs/backlog.md](../docs/backlog.md)
§4/§11c) catches the rename at CI; warn-don't-drop is its on-the-wire runtime
complement.

## Feedback tool (kit expectation)

Every MCP server ships a **`submit_feedback`** tool accepting product feedback,
feature suggestions, bug reports, and similar. The consumer of an MCP server is
an agent acting for a human: when a task hits a limitation of your tools, the
feedback channel should be *right there in the same interface* — reported at
the moment of friction, with context, instead of never. This is an expectation,
not an option; an MCP server without it is incomplete.

- **Contract** (names pinned, like every tool): `kind`
  (`feedback` | `feature-request` | `bug` | `praise`), `summary` (required),
  `detail` and `context` (optional — what the caller was doing when the need
  arose). Returns an acknowledgment id.
- **Durable, never a no-op.** Persist via the repo's persistence choice (table,
  queue, or straight into the issue tracker) and surface entries in the
  operational review cadence ([operations](../docs/operations.md)). A feedback
  tool that drops submissions is worse than none.
- **Low friction, guarded.** Same auth as the rest of the server (no extra
  barrier), never demand PII, and cover it with the standard rate limiter
  ([rate-limiting](../docs/rate-limiting.md)).
- **Invite use in the description** — that is how calling models learn it
  exists: e.g. *"Submit product feedback, a feature suggestion, or a bug
  report. Use this when a task runs into something these tools cannot do."*

```csharp
[McpServerTool(Name = "submit_feedback")]
[Description("Submit product feedback, a feature suggestion, or a bug report. " +
             "Use this when a task runs into something these tools cannot do.")]
public async Task<FeedbackAck> SubmitFeedback(
    [Description("One of: feedback, feature-request, bug, praise")] string kind,
    [Description("One-sentence summary")] string summary,
    [Description("Optional detail — steps, expected vs. actual, links")] string? detail,
    [Description("Optional context — what you were trying to do")] string? context,
    CancellationToken ct) => await _feedback.RecordAsync(kind, summary, detail, context, ct);
```

## Naming (CAF, tokenized)

- azd env: `EffAz-prod` (default `EffAz-prod`).
- Resource group: `rg-glimpse-prod`.
- Host (ACA): `app-glimpse-prod`; App Insights `appi-glimpse-prod`;
  App Config `appcs-glimpse-prod`; Key Vault `kv-glimpse-prod`;
  storage `stglimpseprod`.
- KV + Storage names append a Bicep `uniqueString(resourceGroup().id)` suffix to satisfy
  Azure's global-namespace requirement.

## Auth: OAuth2 resource server — Descope (DCR) recommended

MCP defines its own authorization model. The server is an **OAuth2 resource server**: it
validates a bearer access token on each request, advertises **Protected Resource Metadata**
(PRM) at `/.well-known/oauth-protected-resource` so clients discover the authorization
server, and returns `WWW-Authenticate` on 401.

**Recommended authority: Descope (free tier).** MCP clients (Claude's "Add custom
connector", Cursor, VS Code) should **self-register via Dynamic Client Registration (DCR)**.
Descope supports open DCR (RFC 7591) and CIMD — enable it in the Descope console
(**MCP Servers → enable DCR**). DCR removes the need to pre-register a client and have a
human paste a Client ID + Secret into the connector dialog.

### Validate the token with stock ASP.NET Core JwtBearer

There is **no Descope .NET MCP SDK** (Descope's MCP SDKs are Python/TypeScript). Validate
the access token with the framework's standard JWT bearer middleware against **the MCP
server's Descope agentic-apps OIDC discovery** — no Descope SDK dependency. For an MCP
server the issuer is
`https://api.descope.com/v1/apps/agentic/<DESCOPE_PROJECT_ID>/<MCP_SERVER_ID>` (per-server,
**not** the plain project issuer), and the access token's **`aud` must contain your MCP
server URL** (Descope may issue multiple audiences) — **not** the project ID. Confirm both
values from your MCP server's page in the Descope console:

```csharp
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(o =>
    {
        // Descope agentic-apps issuer for THIS MCP server (project id + MCP server id).
        o.Authority = "https://api.descope.com/v1/apps/agentic/{{DESCOPE_PROJECT_ID}}/{{MCP_SERVER_ID}}";
        o.TokenValidationParameters = new()
        {
            ValidateIssuer = true,
            ValidateAudience = true,
            // aud must CONTAIN your MCP server URL; JwtBearer passes when the token's
            // aud list includes this value (Descope may issue multiple audiences).
            ValidAudience = "{{MCP_SERVER_URL}}",
        };
    });
builder.Services.AddAuthorization();

var app = builder.Build();
app.UseAuthentication();
app.UseAuthorization();
app.MapMcp("/mcp").RequireAuthorization(); // secure /mcp; keep health/version open
```

Serve a **PRM** document at `/.well-known/oauth-protected-resource` pointing at the Descope
authorization server so clients discover where to obtain a token. Keep `/livez` `/readyz`
`/version` unauthenticated.

> **Not the session SDK.** `descopeClient.Auth.ValidateSession(sessionJwt, refreshJwt)` /
> `RefreshSession` / `ValidateAndRefreshSession` is Descope's **web/SPA session-management**
> SDK (session-JWT + refresh-JWT) — **not** how an MCP resource server validates an OAuth2
> access token. Do not wire it into the MCP server.

### Provisioning (free tier)

- Configure the Descope project (DCR, scopes/audience) via the **Management API / agent**
  using a **management key** (created in the Descope console; available on the free tier).
- The **Descope Terraform provider is Pro/Enterprise-only** — on the free tier, provision
  via the Management API, not declarative Terraform.
- The **management key + project ID** are repo credentials: store them as **Key Vault
  references** (managed identity), never in the repo. The seeding/creation process elicits
  them (see [auth.md](../docs/auth.md) confirmation gate).

### Alternative: Entra External ID (back-burnered, DCR-limited)

Entra External ID can be the MCP authority, but **does not offer open DCR** — you must
pre-register a client and have the user paste its Client ID + Secret into the connector.
On Container Apps, advertise PRM and validate the token in-app with the JwtBearer +
PRM setup shown above. This is a documented fallback, **not the recommended path**, and
is not currently in use.

> Auth is situationally sensitive — confirm the authority for this repo during seeding.

<!-- SHARED:avm-secure-defaults v1 -->
## Secure-by-default AVM gotchas (the deploy-blocker cluster)

The AVM modules provision **green** but default to locked-down postures that
leave the running service **healthy-but-broken** — each of these shipped a live
service that looked fine and wasn't (fleet finding, [docs/backlog.md](../docs/backlog.md) §11a).
The per-repo backend bicep MUST set them explicitly:

- **Managed environment blocks public ingress.**
  `avm/res/app/managed-environment` defaults `publicNetworkAccess: 'Disabled'`;
  external ingress then returns `403 "public network access on this managed
  environment is disabled"` and `/readyz` 404/403s with nothing pointing at the
  cause. Set `publicNetworkAccess: 'Enabled'` — the real global boundary is the
  Cloudflare edge + the app rate limiter, not environment isolation.
- **User-assigned identity needs `AZURE_CLIENT_ID` in the container env.**
  > HARD RULE: a container using a user-assigned managed identity with
  > `DefaultAzureCredential` MUST receive `AZURE_CLIENT_ID` as an env var (thread
  > `managedIdentity.outputs.clientId` through). Without it the credential probes
  > a non-existent system-assigned identity and fails — and this is **invisible
  > to a normal smoke test**: `/livez`, `/readyz`, and every non-Azure path stay
  > green while the one path that touches Azure (a Key Vault ref, a Table/Blob
  > write) fails. It ships broken and looks fine.
- **A registry must exist and be wired.** The reference infra provisions no
  container registry; the app also needs a `registries` block (login server +
  pull identity) and the identity needs `AcrPull`. Prefer a **shared** registry
  taken as a parameter over a per-app one ([docs/backlog.md](../docs/backlog.md) §11e);
  cross-subscription `AcrPull` is granted out-of-band (a subscription-scoped
  deployment cannot make a cross-sub role assignment).
- **Storage / KV / App Config network posture.** The seed `shared.bicep` opens
  the storage data plane explicitly (Entra + RBAC only, no VNet — read that
  file's note); when you add any data store, verify it is not left on an AVM
  `Deny` default the same way — the symptom is a `403 AuthorizationFailure` that
  reads exactly like an RBAC bug.

Two runtime facts that read like misconfiguration but are not:

- **Data-plane RBAC propagation lags minutes.** A freshly-assigned data role
  (`Storage Table Data Contributor`, etc.) returns `403` for several minutes
  after assignment; the standard-resilience retry budget on a non-idempotent
  write gives no cushion, so a first call right after provision can fail. Not a
  broken role — wait it out.
- **`azd provision` reverts the container app to the bicep placeholder image**
  (azd never records the real deployed image). Carry the image as an azd-env
  parameter so provisions are image-stable, or re-run
  `az containerapp update --image` after each provision. See
  [docs/deployment.md](../docs/deployment.md) for the az-based deploy path.

<!-- SHARED:cross-cutting-contract v1 -->
## Shared cross-cutting contract (all backends)

Every backend in this kit honors the same contract. Implement via `ServiceDefaults`; do
not hand-roll per service. These endpoints are plain HTTP and live **alongside** `/mcp`.

- **Health:** `/livez` + `/readyz` — owned by the `health-endpoints` skill. See
  [docs/health-checks.md](../docs/health-checks.md).
- **Version:** `/version` derives from the repo `VERSION` file (single source of truth) —
  owned by the `version-source-of-truth` skill; running bits match the deployed tag per
  `tag-version-bits-alignment`. See [docs/versioning.md](../docs/versioning.md).
- **Observability:** OTel → Azure Monitor / App Insights via `ServiceDefaults`. Mask raw
  client IP (geo-resolve to country/region + city, then `0.0.0.0`); `round()` latency
  columns in dashboards, never `toint()`. See [docs/observability.md](../docs/observability.md).
- **Errors:** RFC 9457 Problem Details on every non-MCP error response — owned by the
  `api-designer` skill. (MCP tool failures surface as JSON-RPC errors per the protocol.)
- **Secrets & identity:** Key Vault references + managed identity
  (`DefaultAzureCredential`); no secrets in code, so rotation is a Key Vault op needing no
  redeploy. See [docs/security.md](../docs/security.md).
- **Feature flags:** Azure App Config; new flags default **off**; per-invocation refresh
  middleware (interval alone does not propagate). See [docs/feature-flags.md](../docs/feature-flags.md).
- **Rate limiting:** app-level ASP.NET Core rate limiter is the deployed default — it is
  **per-instance**, so under scale-out the effective limit is `policy × replicas`, not
  global. Respond `429` + Problem Details + `Retry-After` on the HTTP layer.
  The Cloudflare edge is the real global boundary ([edge](../docs/edge.md)).

<!-- SHARED:resilience v1 -->
## Resilience

- `Microsoft.Extensions.Http.Resilience` standard handler wired in `ServiceDefaults`:
  timeout + retry-with-jitter + circuit breaker. Polly events emit via telemetry → OTel.
- **Retry applies to idempotent verbs only.** GET/PUT/DELETE may retry; **POST/PATCH are
  excluded by default** — a blind retry can double-apply a side effect. (Note: a tool that
  mutates state is non-idempotent even though MCP rides over HTTP POST — treat tool retries
  with the same caution.)
- Enabling retry on a non-idempotent verb requires a **commented, justified opt-in** and a
  **STOP-and-ask human gate**: pause for sign-off. The principled escape is an
  **idempotency key** so retries are provably safe.

```csharp
// HARD RULE: retry on POST/PATCH (or a state-mutating tool) requires sign-off +
// an idempotency key. STOP and ask a human before enabling this.
```

<!-- SHARED:persistence-pointer v1 -->
## Persistence

No single baked default — choose per scenario, then follow the matching access idiom:

- **Azure SQL DB** — relational / line-of-business → EF Core.
- **Postgres Flexible + `pgvector`** — relational + AI/RAG → EF Core.
- **Cosmos DB serverless** — NoSQL / scale-to-near-zero → native Cosmos SDK.
- **Storage blobs/tables** — cheap / simple → Storage SDK.

Locks: managed-identity / passwordless DB auth; **migrations applied as a CI/CD step,
never at app startup**. Testcontainers is clean for SQL/Postgres; the Cosmos emulator is
heavy/flaky — prefer an ephemeral serverless DB. See [docs/persistence.md](../docs/persistence.md).

Tests: `xunit.v3` (current major — not the legacy `xunit` 2.x package) +
`WebApplicationFactory`, Testcontainers for relational data. Full stack and
version floors: [docs/testing.md](../docs/testing.md).
