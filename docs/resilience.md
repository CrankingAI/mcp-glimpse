# Resilience

Outbound HTTP resilience is wired once in `ServiceDefaults` via the
**`Microsoft.Extensions.Http.Resilience` standard handler** — timeout +
retry-with-jitter + circuit breaker, on every `HttpClient` the solution creates. No
backend hand-rolls Polly pipelines; they inherit the standard handler.

## The standard handler

`AddStandardResilienceHandler()` applies the standard pipeline: a total request
timeout, a retry strategy with exponential backoff **and jitter**, a per-attempt
timeout, and a circuit breaker. Configure it in `ServiceDefaults` so every typed and
named client gets it by default.

```csharp
// in AddServiceDefaults
builder.Services.ConfigureHttpClientDefaults(http =>
{
    http.AddStandardResilienceHandler();
});
```

## Hard rule: retry idempotent verbs only

Retries are safe **only for idempotent verbs** — `GET`, `PUT`, `DELETE`, `HEAD`.
**`POST` and `PATCH` are excluded from retry by default**, because a retried
non-idempotent request can double-charge, double-create, or double-send.

Enabling retry on a non-idempotent verb is a **STOP-and-ask human gate** (an
`AGENTS.md` hard rule): the agent must pause for sign-off, and the opt-in must be a
**commented, justified** change. The principled escape is an **idempotency key** so
the retry is provably safe even on `POST`.

```csharp
http.AddStandardResilienceHandler(o =>
{
    // Default: retry idempotent verbs only.
    o.Retry.ShouldHandle = args => ValueTask.FromResult(
        IsIdempotent(args.Outcome.Result?.RequestMessage?.Method)
        && IsTransient(args.Outcome));

    // Enabling retry on POST/PATCH requires:
    //   1. a documented idempotency key on the request, AND
    //   2. a STOP-and-ask human sign-off (AGENTS.md hard rule).
    // Do NOT widen ShouldHandle to non-idempotent verbs without both.
});
```

A CI/analyzer check that flags retry-on-`POST` configurations is an optional
reinforcement, not a substitute for the human gate.

## Hard rule: irreversible-action-then-failed-bookkeeping returns success-with-caveat

The retry rule above is the **caller** side. Its mirror is the **handler/tool**
side: when an operation performs an irreversible external action (send an email,
charge a card, enqueue a real-world effect) and the **local bookkeeping
afterward fails** (a ledger write, a status update), the operation MUST return
**success with a caveat** — never a retryable error. A caller that sees a
failure re-invokes the whole operation and **re-fires the irreversible action**
(double-emails, double-charges). This is most acute for **MCP tools, whose
caller is an AI agent that retries on error by default** (see
[backend-mcp](../rules/backend-mcp.md)), but it holds for any handler with
post-action side effects.

- Do the irreversible action, then treat post-action bookkeeping failure as a
  **degraded success**: return the success result, annotate it (a caveat field /
  problem `detail`), and do not surface a status the caller will retry.
- Make the degraded path **observable** — a dedicated ops counter (e.g.
  `ledger_write_failed`) so "succeeded-but-unrecorded" is visible, not silent.
  See [observability](observability.md).
- The durable fix pairs with the idempotency-key escape above: with a key, even
  a full retry is provably safe.

## Telemetry

Retry and circuit-breaker events emit through **Polly telemetry → OTel**, landing in
App Insights via `ServiceDefaults`. Open and half-open circuit transitions, retry
counts, and timeouts are observable — see [observability](observability.md). Do not
add a separate logging path; the standard handler's telemetry is the source.

## Related

- [observability](observability.md) — Polly → OTel telemetry for resilience events.
- [rate-limiting](rate-limiting.md) — the inbound counterpart (429 contract).
- [api-designer skill](skill-dependencies.md) — idempotency-key contract on the API.
