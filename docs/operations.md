# Operations

Operational concerns, distinct from build-time code conventions. Day-2 lives here:
secret rotation, scaling, failover, alerting, backup/restore, cost guardrails.

For build-time wiring this section depends on, see
[observability.md](observability.md), [security.md](security.md),
[deployment.md](deployment.md), and [feature-flags.md](feature-flags.md).

## Diagnose from authoritative sources

Reviewing or troubleshooting **any** activity — a failed API call, a deploy that
didn't take, an auth error, a flaky test, a "saved" that didn't persist — starts by
**reading the real error from the authoritative source**, not by reasoning from
symptoms. Theorizing from symptoms produces confident wrong answers and burns turns;
the actual error message usually settles the question in one query.

Pull the truth first, then analyze:

- **Cloud control plane** — `az ... --debug`, ARM activity logs, the raw HTTP
  response body (status + `error.code` + `error.message`), not just the CLI's
  summarized failure.
- **Entra / identity** — `auditLogs/directoryAudits` and `auditLogs/signIns` (the
  `resultReason` field), the provider's discovery/JWKS docs, decoded token claims.
- **App runtime** — App Insights / OTel traces, exceptions, and dependency failures
  (see [observability.md](observability.md)); structured logs over guesswork.
- **The service's own response** — capture and print the full error payload before
  retrying or working around it; a "generic failure" in a UI usually has a precise
  cause in the API/audit log behind it.

Rule of thumb: **if you find yourself listing hypotheses for why something failed,
stop and go read the log that already knows.** Only theorize once the authoritative
source is genuinely silent (e.g. an opaque `NA` reason) — and say so explicitly when
that happens. Restore is rehearsed, not theorized; failures are diagnosed, not
guessed.

**Operation-results can lie; prefer state reads on flaky / eventually-consistent
backends.** A "failure" toast, a non-2xx return, or an audit row marked `failure` is an
*operation-result* signal — and on flaky or eventually-consistent systems (e.g.
B2C/CPIM, async provisioning, queues) the write can **persist despite a reported
failure**, and a read-back can **lag or come back empty despite success**. So before you
delete, retry, recreate, or "fix" off a reported failure, **corroborate with a *state
read* of the actual resource** — and treat a positive state read as more authoritative
than a contradicting operation-result. (Observed: a portal "Failed to link" toast +
audit `failure` for a user-flow association that had in fact persisted; the truth was the
portal's "already linked" state dialog.) Don't take a destructive action against a
state you only *inferred* from an error message.

## Standing principle: design for operability

Code and infrastructure MUST be built so operational actions are **possible *and*
automatable** — even where this kit only documents the runbook and ships no
automation. Concretely, build so that each of these can be done without a code
change or a risky manual scramble:

- **Secret rotation** — secrets live in Key Vault (references and/or managed
  identity + `DefaultAzureCredential`), never in code, so rotation is a Key Vault
  operation. See [Secrets rotation runbook](#secrets-rotation-runbook).
- **Scaling** — min/max replicas (and scale-to-zero) are explicit infra inputs,
  not hardcoded assumptions.
- **Failover** — health probes (`/livez` + `/readyz`) gate traffic so the platform
  can shift load; the app exposes readiness honestly. See
  [health-checks.md](health-checks.md).
- **Alerting** — signals exist (OTel → App Insights) before alerts are wired on
  top of them. See [Alerting baseline](#alerting-baseline).
- **Backup / restore** — persistence is provisioned with PITR/backup turned on and
  a documented restore path; restore is rehearsed, not theorized.

If a design choice makes any of these impossible to automate later, that is a
design defect — flag it, do not ship around it.

## The operational to-do list is created with the environment

Provisioning the environment (`azd up` into `EffAz-prod`) MUST generate an
**operational to-do checklist** alongside the resources. The environment is not
"done" when the resources exist; it is done when this list is confirmed. The
checklist enumerates the operational items that a fresh `rg-glimpse-prod`
needs a human (or a follow-up automation) to confirm:

- **Backups / PITR** — enabled on the chosen persistence (§9 menu), retention set,
  restore path documented.
- **Data residency** — region of every stateful resource confirmed against the
  residency requirement; cross-region replication decisions recorded.
- **Rotation cadence** — for every secret/key/cert in `kv-glimpse-prod`, a
  rotation interval is set or explicitly waived.
- **Alert wiring** — the [Alerting baseline](#alerting-baseline) alerts exist and
  point at a real action group (not the default empty one).
- **Cost guardrails** — a budget + cost alert on the resource group; scale-to-zero
  / serverless tiers confirmed where intended. See [Cost and scale-to-zero](#cost-and-scale-to-zero).
- **Scale min/max** — replica floor/ceiling set deliberately per workload (cold-start
  tolerance vs. cost).
- **Rate-limit visibility** — 429 / limited-request metrics are flowing to App
  Insights and surfaced on a dashboard/workbook. See [Rate limiting](#rate-limiting).

### Auditing the list

The **`operational-readiness`** skill is the auditor for this checklist. Run it
against a provisioned environment to verify each item is confirmed (or explicitly
waived with a reason) rather than silently skipped. See
[skill-dependencies.md](skill-dependencies.md).

## Secrets rotation runbook

Secrets are AKV-backed and referenced via Key Vault references and/or managed
identity, so **rotation is a Key Vault operation that needs no code change and no
redeploy**. See [security.md](security.md) for the build-time wiring.

Runbook:

1. **Rotate at the source.** Generate the new secret/key (e.g. regenerate a storage
   key, issue a new client secret, rotate a connection string), then write the new
   value as a new **version** of the existing Key Vault secret. Keep the old version
   enabled until step 4.
2. **Let the app pick it up.** Apps read secrets via Key Vault references (Functions
   / ACA app settings) or `DefaultAzureCredential` at runtime. New versions
   are **not** instant: Key Vault references cache, and the configuration provider
   refreshes on its interval (or on restart).
   - **To force immediate refresh:** restart the app (ACA new revision, Functions
     restart). This is the cache/restart-to-refresh behavior — document the chosen
     refresh interval per repo so on-call knows the lag.
3. **Verify.** Confirm `/readyz` is 200 and the dependency that uses the secret is
   healthy on the new value.
4. **Retire the old version.** Disable (do not delete) the previous secret version
   once traffic is confirmed healthy, so rollback is one click.

Cadence is tracked on the [operational to-do list](#the-operational-to-do-list-is-created-with-the-environment).

## Alerting baseline

Alerts sit on top of the telemetry wired in [observability.md](observability.md).
The baseline (minimum every environment confirms):

- **Availability test on `/readyz`** — App Insights standard availability test;
  alert on failure from N locations.
- **Failure-rate alert** — server request failure rate over threshold (5xx + failed
  dependencies).
- **Latency alert** — server response time P95 over threshold. Dashboards render
  durations through `round(...)`, never `toint()` (see observability rules).

Each alert MUST target a real **action group**. SLO / error-budget alerting is a
deferred template, not part of the baseline.

## Rate limiting

The app-level ASP.NET Core rate limiter is the **deployed default**, but be honest
about its boundary:

- The limiter is **per-instance**. Under Functions/ACA scale-out the effective limit
  is `policy × replicas` — it is **not** a global limit.
- **The Cloudflare edge is the global abuse boundary.** The free tier ships a
  real baseline (unmetered DDoS, Free Managed WAF Ruleset, Bot Fight Mode, one
  rate-limiting rule); upgrade the paid ladder (Super Bot Fight Mode, Bot
  Management) when abuse is a genuine concern, not preemptively. See
  [edge](edge.md).
- **Make it observable:** emit 429 / limited-request metrics per policy/route/client
  to App Insights and surface them on a dashboard/workbook. Rate-limit visibility is
  a [to-do list](#the-operational-to-do-list-is-created-with-the-environment) item.
- **API contract:** respond `429` + RFC 9457 Problem Details + `Retry-After`
  (optionally the IETF `RateLimit` / `RateLimit-Policy` header fields); document the
  limits in OpenAPI.

## Cost and scale-to-zero

Cost is an operational input, not an afterthought:

- **Prefer scale-to-zero / serverless tiers** where cold-start tolerance allows —
  Azure Functions (Consumption/Flex), ACA `minReplicas: 0`, Cosmos DB serverless,
  SWA free/standard. The backend decision matrix (§8) weighs cold-start vs. cost.
- **Scale floor is a deliberate choice.** `minReplicas: 0` saves money but pays
  cold-start latency on the first request; set the floor per workload and record it
  on the to-do list.
- **Budget + cost alert** on `rg-glimpse-prod` is a to-do-list item — every
  environment gets one so spend never surprises.
- **The expensive opt-ins are explicit:** the Cloudflare paid ladder (above),
  provisioned throughput, always-on replicas. Document the trade and add them
  deliberately.
