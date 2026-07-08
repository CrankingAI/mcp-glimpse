# Security

No secrets in code. No secrets in config files. No secrets in CI. Everything is
either a **Key Vault reference** resolved at runtime or accessed directly via
**managed identity** with `DefaultAzureCredential`.

## Secrets: Key Vault references + managed identity

- App settings that need a secret hold a **Key Vault reference**
  (`@Microsoft.KeyVault(SecretUri=...)`), not the secret value. The platform
  resolves it at startup using the app's managed identity. The secret itself never
  enters the repo, the pipeline, or the app's plaintext config.
- Service-to-service and data access (Storage, SQL/Postgres, App Config, Service
  Bus) use **managed identity + `DefaultAzureCredential`** — passwordless. Prefer
  this over storing a connection string secret at all; the best secret is the one
  that does not exist.
- Key Vault is `kv-glimpse-prod` (with the global-uniqueness suffix — see
  [deployment](deployment.md)).

## Prefer RBAC over access policies

Grant access to Key Vault with **Azure RBAC**, not the legacy vault access-policy
model. The app's managed identity gets the **`Key Vault Secrets User`** role
(read secret values) — scoped, auditable, and consistent with how every other
Azure resource is authorized.

- Use access policies only for a legacy resource that genuinely cannot use RBAC,
  and document why inline.
- Roles are assigned in Bicep alongside the identity, so least-privilege is
  provisioned, not bolted on.

## Rotation is operational, not a code change

Because secrets are AKV-backed, **rotating a secret is a Key Vault operation that
needs no code change and no redeploy.** You rotate the value in Key Vault; the app
keeps reading the same reference. This is by design — see [operations](operations.md)
for rotation cadence and the operational to-do list.

What you must understand about propagation:

- **Key Vault references are cached by the platform.** Functions / Container Apps
  refresh referenced secrets periodically (on the order of hours), not instantly.
- **To force a refresh, restart the app** (or the slot). After rotating in Key
  Vault, restart so the new value is picked up immediately rather than waiting for
  the cache TTL.
- For direct `DefaultAzureCredential` access there is no secret to cache — the
  identity is the credential, so rotation of an underlying key is transparent.
- Plan rotation around this: rotate in Key Vault, then restart (or let the cache
  expire) during a low-traffic window. With slots/revisions, rotate-and-restart the
  staging target first, verify `/readyz`, then promote.

## Application / user auth

Application and user authentication is **chosen per backend and confirmed per repo
during seeding** — it is situationally sensitive and not silently baked. See
[auth](auth.md) for the full matrix:

- **Workforce** identity → **Entra ID**; **consumer/CIAM** → **Entra External ID**
  (not Azure AD B2C — B2C is legacy, no new tenants).
- Default leans to **platform Easy Auth** (SWA / ACA built-in auth)
  and **OAuth2 resource-server** for MCP. **MSAL/JWT** is the documented path when
  you outgrow Easy Auth or need granular scopes.

The seeding process includes an explicit confirmation gate for the auth choice;
do not assume a default landed silently.

## Telemetry hygiene

Secrets, auth headers, and request bodies must **never** be logged. The raw
client IP never enters app telemetry (IP→geo masking —
[observability](observability.md)); it exists only in the 10-day DNT-scoped
edge log ([edge](edge.md)).

## Vulnerability contact

`/.well-known/security.txt` (RFC 9116) records the contact for vulnerability
reports — see [site-conventions](site-conventions.md).

## Handing a bootstrap credential to a coding agent

One-time human bootstrap steps (`az login`, `gh auth login`, minting a
Cloudflare token that can itself mint tokens, a Descope root key) hand a
privileged credential to whichever agent is doing the scripted setup. Put it
in a local dotfile under `$HOME` (`chmod 600`), not pasted into the
conversation — a pasted secret is permanently in that session's transcript. A
token already pasted should be rotated once its one-time job is done.

## CI

- No **Azure** secret stored in GitHub. Azure deploy auth is **OIDC federated
  credentials / workload identity federation** (see
  [deployment](deployment.md)). **Documented exception:** Cloudflare has no
  OIDC federation, so the CF leg uses least-privilege API tokens in GitHub
  Actions secrets — a zone-scoped `CF_API_TOKEN` for zone configuration and an
  account-scoped `CF_WORKER_DEPLOY_TOKEN` for `wrangler` deploys (see
  [edge](edge.md)); the Worker's Azure leg uses Entra **client credentials**
  (a CF Worker cannot hold a managed identity), scoped to Monitoring Metrics
  Publisher on one DCR.
- `dotnet list package --vulnerable --include-transitive` fails the build;
  Dependabot is on.
