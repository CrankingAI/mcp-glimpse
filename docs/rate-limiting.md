# Rate limiting

The deployed default is the **ASP.NET Core rate limiter** (the
`Microsoft.AspNetCore.RateLimiting` middleware), applied per route/policy. It is the
honest, cheap baseline that ships with every backend.

## Honest caveat: it is per-instance

The app-level limiter is **per-instance, not global**. Under Functions / ACA
scale-out the effective ceiling is `policy × replicas` — a policy of 100 req/s across
4 replicas allows ~400 req/s in aggregate. Document the configured per-instance limit
*and* note that it is not a global limit. Do not claim a global guarantee the
middleware cannot provide.

## The real global boundary (the Cloudflare edge)

The genuine global abuse boundary is the **Cloudflare edge**
([edge](edge.md)). The free tier already ships one rate-limiting rule plus the
WAF/bot baseline; the paid ladder adds unlimited rules when abuse is a real
concern — at that point the per-instance limiter becomes defense-in-depth
behind the edge boundary, not the primary control.

## The 429 contract

When a request is limited, respond with:

- Status **`429 Too Many Requests`**.
- An **RFC 9457 Problem Details** body (`application/problem+json`) — same error model
  as the rest of the API.
- A **`Retry-After`** header.
- Optionally the IETF `RateLimit` / `RateLimit-Policy` header fields.

Document the limits in **OpenAPI** so consumers know them up front.

```csharp
builder.Services.AddRateLimiter(o =>
{
    o.OnRejected = async (ctx, ct) =>
    {
        ctx.HttpContext.Response.StatusCode = StatusCodes.Status429TooManyRequests;
        if (ctx.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter))
        {
            ctx.HttpContext.Response.Headers.RetryAfter =
                ((int)retryAfter.TotalSeconds).ToString();
        }
        await Results.Problem(
            statusCode: StatusCodes.Status429TooManyRequests,
            title: "Too Many Requests").ExecuteAsync(ctx.HttpContext);
    };
    o.AddFixedWindowLimiter("default", opt =>
    {
        opt.PermitLimit = 100;          // per-instance — see caveat above
        opt.Window = TimeSpan.FromSeconds(1);
    });
});

app.UseRateLimiter();
```

## Middleware ordering + rejection gotchas

The sample above is correct; these are the traps behind it (fleet finding,
[backlog.md](../backlog.md) §12) — an adopter who deviates hits them:

- **Default `RejectionStatusCode` is `503`, not `429`.** Set the status
  explicitly (the sample does, in `OnRejected`). **`StatusCodePages` does NOT
  fire for a rate-limiter rejection**, so `OnRejected` must write the
  `application/problem+json` body itself and set `Retry-After` from the lease
  metadata — again, as above.
- **`UseRateLimiter` goes after `UseAuthentication`/`UseAuthorization`** when
  you partition by principal — the identity must exist before you partition on
  it. Bonus: 401s then short-circuit **before** consuming a permit, so
  unauthenticated floods cannot exhaust a shared partition.
- **`PartitionedRateLimiter` caches the materialized limiter per partition key**
  — a config change applies to **new** partitions only, not existing ones. Do
  not claim per-request config freshness; tests only see fresh limits because
  each test host starts with zero partitions.

## Observable

Emit **429 / limited-request metrics** per policy / route / client to App Insights,
and surface them in dashboards / workbooks (`round()`, never `toint()` — see
[observability](observability.md)). A rising 429 rate is the signal that the
per-instance limiter is no longer enough and the edge boundary is due.

## Related

- [observability](observability.md) — 429 metrics + dashboard conventions.
- [resilience](resilience.md) — the outbound counterpart (retry / circuit breaker).
- [api-designer skill](skill-dependencies.md) — RFC 9457 + OpenAPI limit docs.
