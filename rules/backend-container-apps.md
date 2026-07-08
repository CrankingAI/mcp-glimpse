# Backend — Azure Container Apps (.NET 10)

This is the **human-facing HTTP API host**. Containerized .NET 10 on **Azure
Container Apps (ACA)**. Pick this host when you need long-lived processes, custom
container/runtime control, sidecars, or scale shapes (KEDA event/HTTP scaling,
scale-to-zero) that Functions cannot model. It is also the host for a steady,
always-warm API (min replicas ≥ 1) — the case App Service used to cover.

To **also** expose tools to AI agents, additionally keep
[`backend-mcp.md`](backend-mcp.md): MCP is an orthogonal interface that co-hosts
on this ACA host.

This file is self-contained: it does not depend on sibling `rules/backend-*.md`.

## Project shape

- ASP.NET Core 10 minimal API in a container, built with the .NET SDK container
  publish (`dotnet publish /p:PublishProfile=DefaultContainer`) — no hand-written
  Dockerfile unless a base-image or multi-stage need forces one.
- Wire `ServiceDefaults` (OTel → App Insights, resilience, health) — see the
  cross-cutting contract below.
- Catch-all client-routing fallback for any co-hosted SPA: unmatched non-API routes
  rewrite to `index.html`. API routes (`/api/*`, `/livez`, `/readyz`, `/version`) are
  never rewritten.

## Naming (CAF, tokenized)

- azd env: `CrankingAI-prod` (default `EffAz-prod`).
- Resource group: `rg-glimpse-prod`.
- Container App: `app-glimpse-prod`; App Insights `appi-glimpse-prod`;
  App Config `appcs-glimpse-prod`; Key Vault `kv-glimpse-prod`;
  storage `stglimpseprod`.
- KV + Storage names append a Bicep `uniqueString(resourceGroup().id)` suffix to satisfy
  Azure's global-namespace requirement.

## Cost shape (surface before picking this host)

- **Idle / floor:** Consumption with `minReplicas: 0` scales to zero ⇒ **$0 when
  idle**; a low-traffic app typically lands ~$1–5/mo. **`minReplicas: 1+`
  (always-warm) bills that floor 24/7** — the main lever that scales the bill,
  along with Log Analytics ingestion and any
  Cloudflare paid tier added later ([edge](../docs/edge.md)).
- **Meter:** per-second vCPU + GiB (active and idle rates) plus per-request count.
- **Free grant:** per subscription/month — 180,000 vCPU-s + 360,000 GiB-s + 2M
  requests (Consumption).
- **Verify at decision time:** approximate, region-varying, last reviewed
  2026-06-12 — fetch current numbers from the
  [ACA billing docs](https://learn.microsoft.com/azure/container-apps/billing)
  and surface them to the human before this host is chosen.

## Health probes drive everything

ACA wires container probes to the app's health endpoints. The probe contract is owned by
the `health-endpoints` skill — `/livez` (liveness) and `/readyz` (readiness). Do not
re-implement; add the endpoints via that skill and point the ACA probes at them.

- **Liveness** → `/livez`: process is up. Failure restarts the container.
- **Readiness** → `/readyz`: dependencies are reachable and warm. Failure pulls the
  replica out of rotation without restarting it.

See [docs/health-checks.md](../docs/health-checks.md) for the endpoint semantics that the
probes below depend on.

```yaml
# container probe wiring (conceptual — ACA template)
probes:
  - type: Liveness
    httpGet: { path: /livez, port: 8080 }
    initialDelaySeconds: 5
    periodSeconds: 10
  - type: Readiness
    httpGet: { path: /readyz, port: 8080 }
    initialDelaySeconds: 3
    periodSeconds: 5
    failureThreshold: 3
```

## Zero-downtime: single-revision mode (default)

Single-revision mode is the default. ACA brings up the **new** revision and only shifts
ingress traffic to it **after its readiness probe passes**; the old revision keeps serving
until then, so a bad bits push that fails `/readyz` never receives traffic.

- This is the contract enforced by the `zero-downtime-aca-contract` skill — the app MUST
  gate `/readyz` on real readiness (config loaded, dependencies reachable) so the
  no-traffic-until-ready guarantee is meaningful. A `/readyz` that returns 200
  unconditionally defeats it.
- After deploy, verify the new revision actually went active and is serving the expected
  bits with the `aca-deploy-verification` skill (revision state, deployed config, ingress
  posture, App Insights deploy-window queries).

```bash
# single-revision: each deploy creates a new revision; traffic shifts on readiness
az containerapp revision list -n app-glimpse-prod -g rg-glimpse-prod \
  --query "[].{name:name, active:properties.active, traffic:properties.trafficWeight}"
```

## Custom domains

Declare custom domains **in the applied IaC**, never out-of-band:

```bicep
ingress: {
  external: true
  targetPort: int(port)
  customDomains: [
    { name: 'api.mcpglimpse.com', bindingType: 'Auto' }
  ]
}
```

- `bindingType: 'Auto'` with **no `certificateId`**: managed-cert resource names
  are non-deterministic, and `'Auto'` attaches the env-scoped cert when it
  exists (HTTP until then) and self-heals across renewals. Requires
  `Microsoft.App/containerApps@2024-10-02-preview` or later.
- **Never bind hostnames with `az containerapp hostname add/bind` in a
  pipeline.** Every apply re-asserts the full `ingress` object, so out-of-band
  bindings are stripped by the next provision/deploy — observed as a 4–7 min
  public-hostname outage on every deploy until the domains were moved into the
  IaC. A hostname-bind script is fresh-env bootstrap + break-glass only, and
  must treat `bindingType 'Auto'` as already-bound.
- Two irreducibles: (1) `'Auto'` attaches certs but never **creates** them — a
  fresh environment needs a one-time cert-creation step (CLI bind with
  validation, or `az containerapp env certificate create`); (2) ARM validates
  the `asuid.*` TXT record **at PUT time**, so DNS records must exist before
  the first **apply** that declares the domain — `azd provision` in the kit's
  `infra/` shape, `azd deploy` in an Aspire AppHost shape (app modules ride the
  per-service `.tmpl.bicepparam`). Order the DNS reconcile before that apply.
- DNS stays in DNS automation (A/CNAME/`asuid` TXT/CAA). For managed certs the
  records must resolve **directly** (DNS-only / grey-cloud if Cloudflare —
  proxying blocks DigiCert issuance and renewal), and CAA must allow
  `digicert.com`.
  `scripts/cf-domain-bind.sh` automates the grey-cloud → validate →
  orange-cloud sequence ([edge](../docs/edge.md)).
- **Cert validation method: CNAME = subdomain, TXT = apex only.** CNAME is the
  default (~2.5 min). TXT is the escape hatch for an apex behind a flattening
  proxy where CNAME validation can't reach — it is **not** a general option.
  Using `--validation-method TXT` on a **subdomain** is CLI-accepted, sits
  `Pending` ~80 min, then goes terminal `Failed`; worse, a `Pending` cert 500s
  on delete until it reaches that terminal state, so there is no fast abort
  (fleet finding — ~80 min dead time from copy-pasting an apex runbook onto a
  subdomain, [docs/backlog.md](../docs/backlog.md) §14).
- Guard the contract: a static CI check that each module still declares its
  expected hostnames (a regenerated module silently drops them), plus an
  outside-in TLS gate (issuer + expiry + health path) post-deploy and on a
  schedule — a failed renewal under `'Auto'` silently downgrades to HTTP.
- Known azd gotcha (until fixed upstream): azd's vendored ACA SDK
  (`armappcontainers` v3.1.0) predates `'Auto'`, so its **post-apply read**
  fails (`cannot unmarshal number into ... BindingType`) *after* the bits and
  domains have applied — and aborts any remaining services. azd's documented
  fix (`services.<svc>.apiVersion` in `azure.yaml`) is dropped by the Aspire
  importer when it synthesizes per-resource services, so for Aspire repos:
  deploy per service, soft-fail **only** that exact signature, and let outcome
  gates (a `/version`-vs-tag assert + the TLS gate) arbitrate real success.

## Blue-green: multi-revision mode + traffic split

For canary or blue-green, switch to **multi-revision mode** and split ingress weight
across labelled revisions. Shift weight only after the new revision's `/readyz` is green
and the deploy-verification checks pass.

```bash
# 90/10 canary, then promote to 100 once verified
az containerapp ingress traffic set -n app-glimpse-prod -g rg-glimpse-prod \
  --revision-weight blue=90 green=10
az containerapp ingress traffic set -n app-glimpse-prod -g rg-glimpse-prod \
  --revision-weight green=100
```

- Promotion = **build once, shift traffic** — never rebuild per stage. The same image
  digest that ran as `green` at 10% is the image promoted to 100%.
- Stamp each revision so you can correlate traffic with bits (see
  `tag-version-bits-alignment`): the running revision's reported `/version` must match the
  deployed image tag.

## Auth: ACA built-in auth

Use **ACA built-in authentication** (the platform auth/authZ middleware, "Easy Auth"
equivalent) as the default — Entra ID for workforce, Entra External ID for consumer/CIAM.
The platform terminates auth before the request reaches the container; the app reads the
injected principal headers. Reach for app-level MSAL/JWT only when you outgrow built-in
auth (granular scopes, custom token validation), and record that decision as an
ADR ([docs/adr](../docs/adr/README.md)).

> Auth is situationally sensitive — confirm the auth choice for this repo during seeding;
> do not assume the default silently applies.

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
not hand-roll per service.

- **Health:** `/livez` + `/readyz` — owned by the `health-endpoints` skill. See
  [docs/health-checks.md](../docs/health-checks.md).
- **Version:** `/version` derives from the repo `VERSION` file (single source of truth) —
  owned by the `version-source-of-truth` skill; running bits match the deployed tag per
  `tag-version-bits-alignment`. See [docs/versioning.md](../docs/versioning.md).
- **Observability:** OTel → Azure Monitor / App Insights via `ServiceDefaults`. Mask raw
  client IP (geo-resolve to country/region + city, then `0.0.0.0`); `round()` latency
  columns in dashboards, never `toint()`. See [docs/observability.md](../docs/observability.md).
- **Errors:** RFC 9457 Problem Details on every error response — owned by the
  `api-designer` skill.
- **Secrets & identity:** Key Vault references + managed identity
  (`DefaultAzureCredential`); no secrets in code, so rotation is a Key Vault op needing no
  redeploy. See [docs/security.md](../docs/security.md).
- **Feature flags:** Azure App Config; new flags default **off**; per-invocation refresh
  middleware (interval alone does not propagate). See [docs/feature-flags.md](../docs/feature-flags.md).
- **Rate limiting:** app-level ASP.NET Core rate limiter is the deployed default — it is
  **per-instance**, so under scale-out the effective limit is `policy × replicas`, not
  global. Respond `429` + Problem Details + `Retry-After`. The Cloudflare edge
  is the real global boundary ([edge](../docs/edge.md)).

<!-- SHARED:resilience v1 -->
## Resilience

- `Microsoft.Extensions.Http.Resilience` standard handler wired in `ServiceDefaults`:
  timeout + retry-with-jitter + circuit breaker. Polly events emit via telemetry → OTel.
- **Retry applies to idempotent verbs only.** GET/PUT/DELETE may retry; **POST/PATCH are
  excluded by default** — a blind retry can double-apply a side effect.
- Enabling retry on a non-idempotent verb requires a **commented, justified opt-in** and a
  **STOP-and-ask human gate**: pause for sign-off. The principled escape is an
  **idempotency key** so retries are provably safe.

```csharp
// HARD RULE: retry on POST/PATCH requires sign-off + an idempotency key.
// STOP and ask a human before enabling this. Do not silently flip it on.
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
