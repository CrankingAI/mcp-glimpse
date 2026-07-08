# Feature flags

Feature flags live in **Azure App Configuration**, read through
`Microsoft.FeatureManagement`. Flags are flipped in App Config (`appcs-glimpse-prod`)
without a redeploy — the value is data, not code.

## Hard rule: new flags default OFF

Every new flag ships **off**. A flag is dark until it is deliberately turned on,
per environment. This is a non-negotiable rule from `AGENTS.md`: never merge a flag
that is on by default.

## Wiring

- App Config is accessed via **managed identity** (`DefaultAzureCredential`), no
  connection string secret — see [security](security.md).
- Register App Config as a configuration source and enable feature management +
  the refresh pipeline at startup.

```csharp
builder.Configuration.AddAzureAppConfiguration(options =>
{
    options.Connect(new Uri(appConfigEndpoint), new DefaultAzureCredential())
           .UseFeatureFlags(ff =>
           {
               // Floor only — see "the refresh gotcha" below.
               ff.SetRefreshInterval(TimeSpan.FromSeconds(30));
           });
});

builder.Services.AddAzureAppConfiguration();
builder.Services.AddFeatureManagement();
```

## The refresh gotcha (read this)

`SetRefreshInterval` is **only a floor** — it caps how often a refresh *may* hit
the service. It does **not** schedule refreshes on its own. The thing that actually
re-reads flag values on a running instance is the
**`AzureAppConfigurationRefreshMiddleware`**, which evaluates on each request /
invocation (no more often than the interval allows).

**Without the middleware in the pipeline, a flag flip never reaches a running
instance — it only takes effect on the next restart.** This is the single most
common App Config mistake. Add it:

```csharp
// ASP.NET Core: per-request refresh trigger.
app.UseAzureAppConfiguration();
```

For Azure Functions / isolated worker, register the equivalent middleware so each
invocation triggers the refresh check. The pattern is the same: a per-invocation
trigger is what propagates flips; the interval only throttles it.

## Read flags with the Snapshot interfaces

Inject the **snapshot** variants so every flag and option is consistent for the
lifetime of a single request — never the singleton `IOptions<T>`, which captures
the value once at startup and never sees a flip.

| Use | Inject | Never inject |
|---|---|---|
| Simple on/off flag | `IVariantFeatureManagerSnapshot` (or `IFeatureManagerSnapshot`) | `IFeatureManager` (singleton) |
| Flag-driven options | `IOptionsSnapshot<T>` | `IOptions<T>` |

```csharp
public sealed class CheckoutEndpoint(IVariantFeatureManagerSnapshot features)
{
    public async Task<IResult> Handle(CancellationToken ct)
    {
        if (await features.IsEnabledAsync("NewCheckout", ct))
        {
            // new path
        }
        // ...
    }
}
```

`IOptionsSnapshot<T>` / `IVariantFeatureManagerSnapshot` are scoped: they re-read
once per request, so a flip that the middleware pulled in is reflected immediately
on the next request. `IOptions<T>` is a singleton and will silently serve the
startup value forever — that is the bug the snapshot interfaces prevent.

## Summary of the failure modes

- Forgot `UseAzureAppConfiguration()` middleware → flips only apply on restart.
- Injected `IOptions<T>` / `IFeatureManager` → flips never apply at all (frozen at
  startup), even with the middleware.
- New flag shipped on → violates the default-OFF rule.

## Related

- [security](security.md) — managed-identity access to App Config.
- [deployment](deployment.md) — flags are flipped in App Config, not redeployed.
