# Observability

OpenTelemetry → Azure Monitor / Application Insights, wired once in a shared
`ServiceDefaults` library. Traces, metrics, and structured logs flow through the same
pipeline. Every backend references `ServiceDefaults`; no backend configures OTel
exporters on its own.

## ServiceDefaults

`ServiceDefaults` is the **Aspire-template-generated** project (`AddServiceDefaults()`),
**not a NuGet package**. It is generated into the solution and edited in-repo. The one
required change from the template default: **redirect the OTLP exporter to Azure
Monitor** via `UseAzureMonitor()` / `AddAzureMonitorExporter`, so telemetry lands in
App Insights instead of a local OTLP collector.

It owns:

- OTel tracing, metrics, and logging registration.
- The Azure Monitor exporter (connection string from config / Key Vault ref).
- Resilience handler telemetry (Polly → OTel) and default HTTP instrumentation.
- The `ClientIpEnrichingProcessor` (below).

## Privacy-preserving geo (MANDATORY)

In the **app telemetry pipeline** we track client geography at
**country/region + city** granularity and **never retain the raw client IP**.
This is not optional and not configurable per repo. (The Cloudflare edge log
is a separate, DNT-scoped pipeline — raw IP + UA live there ≤ 10 days, then
auto-purge; see [edge](edge.md).)

The mechanism (matching the `icanhazdomain` reference) is an OTel
`BaseProcessor<Activity>` that, at span `OnEnd`, stamps the corrected client IP onto
the span as `client.address`. **Azure Monitor geo-resolves that IP server-side** into
`client_CountryOrRegion` and `client_City`, and **App Insights masks the stored IP to
`0.0.0.0` by default** after the lookup (leave IP masking on — do **not** set
`DisableIpMasking`). So the raw IP is used only for the server-side geo lookup and is
never retained. No in-process geo database or per-request callout is needed.

The processor stamps at **`OnEnd`** — and that timing is load-bearing. The OTel
ASP.NET Core instrumentation captures `client.address` at span *start*, from
`Connection.RemoteIpAddress`, **before** `ForwardedHeaders` has rewritten it from
`X-Forwarded-For`. Reading the corrected IP at `OnEnd` (after `ForwardedHeaders` ran)
is what yields the real caller behind the Cloudflare edge / SWA / ACA ingress rather than the
proxy's datacenter IP.

```csharp
// ServiceDefaults/ClientIpEnrichingProcessor.cs
using System.Diagnostics;
using Microsoft.AspNetCore.Http;
using OpenTelemetry;

/// <summary>
/// Stamps the real caller IP onto server request spans as client.address so Azure
/// Monitor geo-resolves it (filling client_CountryOrRegion / client_City) instead of
/// the ingress front end's datacenter IP. The IP is used ONLY for the server-side geo
/// lookup; App Insights masks the stored address to 0.0.0.0 by default, so it is not
/// retained. Read at OnEnd because the OTel instrumentation captures client.address at
/// span start, before ForwardedHeaders has rewritten it from X-Forwarded-For.
/// </summary>
public sealed class ClientIpEnrichingProcessor(IHttpContextAccessor accessor)
    : BaseProcessor<Activity>
{
    public override void OnEnd(Activity activity)
    {
        if (activity.Kind != ActivityKind.Server)
        {
            return;
        }

        var ip = accessor.HttpContext?.Connection.RemoteIpAddress?.ToString();
        if (!string.IsNullOrEmpty(ip))
        {
            // Doc-sanctioned attribute the Azure Monitor exporter feeds to geo lookup.
            activity.SetTag("client.address", ip);
        }
    }
}
```

Register it in `ServiceDefaults` (ensure `IHttpContextAccessor` is registered and
`ForwardedHeaders` is configured ahead of it):

```csharp
// in AddServiceDefaults / tracing setup
tracing.AddProcessor<ClientIpEnrichingProcessor>();
```

Reference implementation: the `icanhazdomain` MCP `ClientIpEnrichingProcessor.cs`.

## round() in dashboards and workbooks — never toint()

Every duration/latency column rendered to a human in a KQL dashboard or workbook MUST
be wrapped in `round(...)`. `percentile()` and raw `duration` are fractional
milliseconds; sub-millisecond precision on multi-second latencies is noise.

**Never `toint()`** — it truncates downward and under-reports latency.

```kql
requests
| summarize p95 = round(percentile(duration, 95), 1) by bin(timestamp, 5m)
```

Reference: `icanhazdomain` `infra/modules/observability.bicep`.

## Client-side RUM (SPA only)

Real-user monitoring uses the **Application Insights JavaScript SDK** and is scoped to
the **`/app/*` SPA layer ONLY**. The public Astro shell stays **script-free** (AEO
legibility + first-GET principle — see [seo-discoverability](seo-discoverability.md)).

RUM is **wired to cookie consent**: no App Insights JS initializes until the user
consents. This ties to the **privacy-policy-drafter** skill, which drafts the policy
covering the analytics in use. Do not add RUM to the shell, and do not initialize it
ahead of consent.

**Product analytics is a peer of RUM.** A product-analytics SDK (e.g.
PostHog) follows the same rules: `/app/*` SPA layer only, initialized only
after cookie consent, covered by the same privacy-policy-drafter tie-in. Turn
on PostHog's project-level **"Discard client IP data"** — GeoIP enrichment
runs at ingest *before* the discard, so events keep geo without retaining IP.
The server-side leg of the same PostHog project is the edge log
([edge](edge.md)), which covers the surfaces where no script can run.

## PII / log-scrubbing baseline

These must NEVER reach telemetry, logs, or traces:

- Request and response **bodies**.
- **Auth headers** (`Authorization`, cookies, tokens).
- **Secrets** (connection strings, keys, anything from Key Vault).
- **Raw client IP** — only country/region + city here, via the processor
  above. Raw IP exists solely in the 10-day edge log ([edge](edge.md)).

This baseline is enforced in `ServiceDefaults` (filtered instrumentation) plus Azure
Monitor's default IP masking (do not set `DisableIpMasking`). Logging a body or header
to debug is a STOP-and-fix, not a quick patch.

## Edge telemetry

The Cloudflare edge Worker logs watched-path hits (verified-bot classified)
into the same Log Analytics workspace as app telemetry — `EdgeHits_CL`
(10-day retention) joins `AppRequests` / `ContainerAppHTTPLogs` in one KQL
query. That join is the Observability-Maximalist payoff: edge view and origin
view side by side. Pipeline, sinks, and queries: [edge](edge.md).

## Alerting baseline (operational)

Operational alerting lives with [operations](operations.md); the observability baseline
defines the three alerts every workload ships with:

- **Availability test** — App Insights test against `/readyz` (see
  [health-checks](health-checks.md)).
- **Failure-rate alert** — request failure percentage over threshold.
- **Latency alert** — p95 request latency over threshold (`round()`, not `toint()`).

SLO / error-budget templates are deferred.
