# Entra External ID — best-practice checklist

Machine-checkable best practices for an **Entra External ID (CIAM)** deployment that powers
an **MCP OAuth2 resource server** + a **SPA public client** + a **confidential client**, with
a **consumer self-service sign-up** user flow. Each rule has an id, severity, the live signal
to inspect, the pass criteria, and a one-line fix. `scripts/entra-external-id-doctor.sh`
automates the subset that is checkable from Microsoft Graph / `az` / HTTP. Grounded in
Microsoft Learn (2025–2026) + the MCP authorization spec (2025-06-18) + RFC 9728/8707.

Severity: **C**ritical · **H**igh · **M**edium · **L**ow. `applies_to`: api · spa · confidential · userflow · tenant · mcp-host · any.

## 1. App registration & credential hygiene

| id | sev | applies | check (Graph `/applications`, `/servicePrincipals`) → pass | fix |
|---|---|---|---|---|
| spa-redirect-https-no-wildcard | H | spa | `spa.redirectUris` all https (loopback ok for dev), no `*`, no `urn:` | exact https URIs only |
| web-redirect-https-no-wildcard | H | confidential | `web.redirectUris` all https/loopback, no wildcard | exact https URIs only |
| spa-uris-under-spa-platform | H | spa | browser URIs in `spa.redirectUris`, NOT in `web`/`publicClient` | move URIs to the spa platform |
| spa-no-implicit-access-token | H | spa | `web.implicitGrantSettings.enableAccessTokenIssuance == false` | disable implicit; use PKCE |
| spa-no-implicit-id-token | H | spa | `web.implicitGrantSettings.enableIdTokenIssuance == false` | disable implicit; use PKCE |
| spa-no-credentials | H | spa | `passwordCredentials == [] && keyCredentials == []` | delete creds from public client |
| confidential-prefer-cert-or-fic | H | confidential | `keyCredentials` or `federatedIdentityCredentials` present AND `passwordCredentials == []` | replace secret with cert/FIC |
| secret-bounded-expiry | M | confidential | every `passwordCredentials[].endDateTime` future AND lifetime ≤180d | reissue ≤180d, rotate via KV |
| cert-bounded-expiry | L | confidential | every `keyCredentials[].endDateTime` future AND lifetime ≤365d | rotate certs ≤1y |
| no-expired-credentials | M | any | no `password/keyCredentials[].endDateTime < now` | delete expired creds |
| credential-count-minimal | L | confidential | `count(password)+count(key) ≤ 2` | trim to active + one rollover |
| api-requested-access-token-v2 | H | api | `api.requestedAccessTokenVersion == 2` | set to 2 |
| api-identifier-uri-form | M | api | `identifierUris` non-empty, `api://<appId>` form, no `*`, no trailing `/` | set App ID URI to `api://<appId>` |
| sign-in-audience-single-tenant | M | any | `signInAudience == "AzureADMyOrg"` (unless multitenant is justified) | set AzureADMyOrg |
| app-has-owner | H | any | `/applications/{id}/owners` count ≥ 1 | assign named owner(s) |
| app-instance-lock-enabled | M | any | `servicePrincipalLockConfiguration.isEnabled == true && allProperties == true` | enable app instance property lock |
| confidential-not-fallback-public | M | confidential | `isFallbackPublicClient` false/null for a web client | set "allow public client flows" = No |
| no-stray-platform-uris | L | any | only the app-type's platform holds redirect URIs | remove URIs on unused platforms |

## 2. Scopes, permissions & consent

| id | sev | applies | check → pass | fix |
|---|---|---|---|---|
| api-custom-scope-exists | H | api | `api.oauth2PermissionScopes[]` has enabled `Inform.Send` | add the delegated scope |
| api-scope-type-user | M | api | `Inform.Send` `.type == "User"` (user-consentable) | set "Admins and users" |
| api-scope-naming | L | api | scope value matches `^[A-Za-z][A-Za-z0-9._-]{0,119}$`, granular `Resource.Operation` | rename granular |
| api-no-unused-app-roles | M | api | no enabled `appRoles[]` with `Application` member type unless a daemon needs it | remove unused app roles |
| client-requests-only-inform-send | H | any | each client's `requiredResourceAccess[apiAppId]` lists exactly `Inform.Send`, `type==Scope` | request only Inform.Send |
| client-resourceaccess-type-scope | H | any | client→API `resourceAccess[].type == "Scope"` (never `Role`) | use delegated, not app, perm |
| client-minimal-graph-permissions | H | any | Graph block ⊆ {openid, profile, offline_access, User.Read}, all `Scope` | trim Graph perms |
| client-no-graph-app-roles | H | any | zero Graph `resourceAccess.type == "Role"` on clients | delete Graph app perms |
| client-no-high-priv-graph-granted | H | any | client SP `appRoleAssignments` (Graph) exclude Directory/Application.ReadWrite.All etc. | revoke high-priv grant |
| spa-no-application-permissions | H | spa | SPA has no `Role` resourceAccess and no `appRoleAssignments` | delegated only |
| consent-admin-allprincipals | H | any | one `oauth2PermissionGrant` per client→API, `consentType==AllPrincipals`, scope incl. `Inform.Send` | grant admin consent |
| consent-grant-not-overbroad | M | any | each grant's scopes ⊆ the client's declared scopes | re-create least-priv grant |
| consent-no-stray-graph-grants | M | any | AllPrincipals Graph grants ⊆ sign-in basics | reduce Graph grant |
| api-preauthorize-trusted-clients | M | api | `api.preAuthorizedApplications[]` covers each first-party client w/ Inform.Send | pre-authorize clients |
| api-preauth-ids-valid | L | api | preauth `delegatedPermissionIds` map to enabled scopes; appIds real | remove stale entries |
| api-assignment-required-for-roles | M | api | if app roles exposed, API SP `appRoleAssignmentRequired == true` | set "assignment required" = Yes |
| client-no-mixed-permission-types | M | any | a client's resourceAccess types are not both {Scope,Role} | split daemon into own reg |

## 3. External-tenant security & user flow

| id | sev | applies | check (Graph v1.0 + beta) → pass | fix |
|---|---|---|---|---|
| ca-mfa-policy-enabled | H | tenant | a CA policy `state==enabled`, `grantControls.builtInControls` has `mfa`, targets customers+app | create enabled MFA CA policy |
| ca-mfa-not-report-only | H | tenant | that policy `state == "enabled"` (not `enabledForReportingButNotEnforced`) | flip report-only → enabled |
| ca-mfa-breakglass-excluded | M | tenant | MFA policy excludes ≥1 break-glass account/group | exclude emergency account |
| userflow-has-identity-provider | H | userflow | flow `onAuthenticationMethodLoadStart.identityProviders[]` non-empty | add an IdP to the flow |
| userflow-first-factor-intended | M | userflow | identityProviders = the intended set (Email OTP only) | remove unused IdPs |
| userflow-attribute-minimization | M | userflow | collected attributes ⊆ {email, displayName} | trim collected attributes |
| userflow-linked-to-application | H | userflow | flow `conditions.applications.includeApplications[]` has the prod appIds | link apps to the flow |
| authpolicy-email-otp-enabled | H | tenant | `authenticationMethodsPolicy/.../email` state enabled + `allowExternalIdToUseEmailOtp` in {enabled,default} | enable email OTP |
| authpolicy-sms-not-unnecessary | M | tenant | `.../sms` state `disabled` unless explicitly needed ($, SIM-swap) | disable SMS unless required |
| authzpolicy-signup-intentional | M | tenant | `authorizationPolicy` signup flags match intended (e.g. `allowEmailVerifiedUsersToJoinOrganization=false`) | set intended posture |
| authzpolicy-guest-invite-restricted | L | tenant | `allowInvitesFrom` in {none, adminsAndGuestInviters} | restrict invites |
| authzpolicy-no-risky-app-consent | L | tenant | `allowUserConsentForRiskyApps == false` | disable risky-app consent |
| branding-custom-not-default | L | tenant | `/organization/{id}/branding` customized (logo/colors/text) | configure company branding |
| custom-url-domain-branded | M | tenant | sign-in host is a verified custom domain, not `<tenant>.ciamlogin.com` | configure custom URL domain |
| token-lifetime-managed | L | tenant | a token-lifetime policy or CA session control (signInFrequency/persistentBrowser) is set | set session controls |
| data-residency-awareness | L | tenant | tenant geo == intended (immutable post-creation — verify only) | (recreate tenant if wrong) |
| monitoring-diagnostic-export | L | tenant | diagnostic setting exports SignInLogs/AuditLogs to Log Analytics | add diagnostic setting |

## 4. MCP / OAuth2 resource server (App Service Easy Auth + PRM)

> **Scope note (2026-06-08):** this section verifies the **App Service Easy Auth +
> PRM** mechanism. App Service is **no longer a kit host** (see the AGENTS.md backend
> topology — backends are Functions + ACA), so this is **reference for diagnosing an existing Easy Auth
> deployment**, not the kit's default. The kit's MCP server now runs on **Container
> Apps and validates the token *in-app*** — ASP.NET Core `JwtBearer` + a hand-served
> PRM document (see [backend-mcp.md](../rules/backend-mcp.md)). The **protocol-level**
> rows below still apply on ACA (PRM served/valid/`.resource`/`.authorization_servers`,
> 401 + `WWW-Authenticate` with `resource_metadata`, audience binding, full token
> validation, no token pass-through / no token in query, health/PRM reachable
> unauthenticated). The **App-Service-platform-config** rows have in-app equivalents:
> `auth-enabled`/`auth-return401` → secure `/mcp` with `RequireAuthorization()` (a
> failed bearer returns 401, never a login redirect); `prm-scopes-setting-present`
> (`WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES`) → list the scope in the in-app PRM
> document; `https-only` (`httpsOnly`) → ACA ingress `allowInsecure == false`;
> `auth-allowed-clients` → enforce any client allowlist in the authorization policy.

| id | sev | applies | check (HTTP + `az webapp auth show`) → pass | fix |
|---|---|---|---|---|
| prm-endpoint-served | C | mcp-host | GET `/.well-known/oauth-protected-resource` → 200 JSON | enable Easy Auth + PRM setting |
| prm-valid-json | C | mcp-host | PRM body parses as JSON | rely on default PRM |
| prm-resource-field | C | mcp-host | PRM `.resource` == canonical MCP URI (https, no trailing-slash mismatch) | reach app via real hostname |
| prm-auth-servers | C | mcp-host | PRM `.authorization_servers[]` → the External ID authority | point OIDC at External ID |
| prm-scopes-inform-send | H | mcp-host | PRM `.scopes_supported[]` includes `Inform.Send` | set PRM scopes setting |
| mcp-401-www-authenticate | C | mcp-host | unauth `/mcp` → 401 + `WWW-Authenticate: Bearer ... resource_metadata="…"` | Return401 + PRM setting |
| auth-return401 | C | mcp-host | `globalValidation.unauthenticatedClientAction == "Return401"` | not RedirectToLoginPage |
| auth-enabled | C | mcp-host | `platform.enabled==true && globalValidation.requireAuthentication==true` | enable Easy Auth + require |
| oidc-config-externalid | C | mcp-host | custom OIDC `wellKnownOpenIdConfiguration` == External ID v2.0 discovery; issuer matches | point at ciamlogin discovery |
| auth-audience-matches-appiduri | C | mcp-host | validated `aud` == API App ID URI == PRM `.resource` == scope prefix | bind audience to `api://<id>` |
| token-validation-full | C | mcp-host | wrong aud/iss/sig → 401; missing scope → 403; only valid+Inform.Send succeeds | validate iss+aud+sig+scope |
| prm-scopes-setting-present | H | mcp-host | app setting `WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES` incl. `api://…/Inform.Send` | set the app setting |
| https-only | H | mcp-host | `httpsOnly == true`; http → redirect to https | enable HTTPS-only |
| health-version-excluded | M | mcp-host | `/livez /readyz /version` return 200 unauthenticated | add to excludedPaths |
| prm-wellknown-excluded | H | mcp-host | PRM endpoint reachable unauthenticated (200) | keep PRM anonymous |
| no-token-passthrough | H | mcp-host | client token NOT forwarded downstream (ACS via managed identity / OBO) | use MI/OBO downstream |
| mcp-no-token-in-query | M | mcp-host | `/mcp?access_token=…` (no header) → 401 | only accept Authorization header |
| auth-allowed-clients | M | mcp-host | MCP client appId in `defaultAuthorizationPolicy.allowedApplications` (if restricted) | allow the MCP client app |

## 5. Operations, monitoring & secret lifecycle

| id | sev | applies | check (Graph + `az`) → pass | fix |
|---|---|---|---|---|
| app-owners-present | H | any | every app `/owners` ≥ 1 | assign owners |
| no-checked-in-secret | C | any | tracked files have no literal secret/connection-string/account-key | move to Key Vault |
| ci-uses-federated-credentials | H | confidential | CI deploy identity has GitHub-OIDC `federatedIdentityCredentials` + no secret | use OIDC, drop secret |
| runtime-managed-identity-not-connstr | H | tenant | web app has MI; Storage/ACS via MI/RBAC or KV ref, not inline conn-string | MI + RBAC; KV ref otherwise |
| storage-least-privilege-rbac | H | tenant | runtime MI holds Storage **Table Data Reader/Contributor**, not Owner/Contributor | assign narrow data role |
| storage-shared-key-disabled | M | tenant | `allowSharedKeyAccess == false` | disable Shared Key |
| keyvault-rbac-secrets-user | M | tenant | KV `enableRbacAuthorization==true`; MI has only **Key Vault Secrets User** | RBAC + least role |
| entra-logs-to-log-analytics | H | tenant | diagnostic setting streams Sign-in + Audit logs to Log Analytics | add diagnostic setting |
| credential-expiry-alerting | M | confidential | no active credential expiring ≤30d without tracked rotation | scan + alert on a schedule |
| remove-unused-credentials | M | confidential | `staleAppCreds` recommendation has no active impacted resources | remove unused creds |
| remove-unused-apps | M | any | `staleApps` recommendation clear (or justified) | soft-delete unused apps |
| ca-privileged-roles-phish-resistant-mfa | H | tenant | enabled CA policy requires phishing-resistant MFA for admin roles | add admin-MFA CA policy |
| block-legacy-auth | M | tenant | enabled CA policy blocks legacy auth client types | add block-legacy CA policy |
| restrict-app-registration | M | tenant | `authorizationPolicy.defaultUserRolePermissions.allowedToCreateApps == false` | restrict app creation/consent |
| keyvault-diagnostics-enabled | L | tenant | KV `AuditEvent` logs export to Log Analytics | enable KV audit logging |

## Notes & gotchas (load-bearing)

- **External tenants have NO MFA by default** — enforcement needs a CA policy *plus* MFA in the user flow. **ID Protection is unsupported** in external tenants, so log export + alerting is the detection layer.
- **App Service PRM is preview**; `WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES` is the single switch that drives `scopes_supported`, the challenge scopes, AND the `resource_metadata` WWW-Authenticate behavior. **ACA has no equivalent platform PRM switch** — on the kit's ACA MCP host, serve the PRM document and emit the `resource_metadata` challenge **in-app** (see [backend-mcp.md](../rules/backend-mcp.md)).
- **Audience binding (RFC 8707)**: PRM `.resource`, Easy Auth audience, and the `Inform.Send` scope prefix must be the **same** `api://…` identifier.
- **Custom OIDC providers have no `allowedAudiences`** field on App Service — the provider `clientId` *is* the audience gate; confirm a real token's `aud` matches it.
- `oauth2PermissionGrants.scope` is a **space-delimited string**, not an array. Microsoft Graph appId is the constant `00000003-0000-0000-c000-000000000000`.
- User-flow handlers (`authenticationEventsFlows/.../externalUsersSelfServiceSignUpEventsFlow`) are **beta** Graph.
- **SMS** second factor is a paid add-on (linked subscription; sign-in breaks if it lapses), SIM-swap risk, many regions off by default since Jan 2025 — prefer Email OTP / passkeys.

## Field-learned gotchas (CPIM / user-flow association)

Hard-won during the inform-human build — these will save hours:

- **A new external tenant's CPIM/policy backend provisions SLOWLY and asynchronously**
  (observed **~10 hours**). The OIDC front door (`.../v2.0/.well-known/openid-configuration`)
  comes up first; the B2C/CPIM **policy** plane (user-flow association) lags well behind.
  `provisioningState: Succeeded` on the ARM `ciamDirectories` resource means the *directory*
  is ready, **not** CPIM.
- **The Graph user-flow association *write* is effectively broken for these tenants.**
  `POST .../authenticationEventsFlows/{id}/.../conditions/applications/includeApplications/$ref`
  (and the equivalent PATCH) return **`400 "This API is not supported for AAD accounts
  (no addressUrl for Microsoft.CPIM,False)"`** regardless of identity (user OR app-only token)
  or CPIM readiness. **Associate apps in the Entra admin center portal — not via Graph.**
- **The Graph association *read* is unreliable** — `includeApplications` returns **empty even
  when apps are linked**. A positive read is trustworthy; a negative read is a false-negative,
  not proof of "not linked". The authoritative read is the portal: the **"already linked"
  dialog** or **Run user flow** app list.
- **Operation-result signals can LIE on this flaky backend.** A portal **"Failed to link"
  toast** and an **`auditLogs/directoryAudits` "failure" (reason `NA`, `loggedByService: B2C`,
  `category: PolicyManagement`)** were both emitted for writes that **actually persisted**.
  On flaky/eventually-consistent backends, **corroborate a reported failure with a *state read*
  before acting on it** — don't delete/retry/recreate off an operation-result alone.
- **An app links to exactly one user flow** ("Applications can only be linked to a single user
  flow"). Re-linking moves it. A self-service-signup flow's **`priority` must be `500`**;
  multiple flows can coexist at 500.
- **A confidential/`web` app linked fine** — `web`-vs-`spa` platform is **not** a linkability
  factor (a wrong theory I chased before reading the audit log). Use the **`web` platform**.
- **⚠️ CORRECTION (field-proven 2026-06-05): a public/PKCE-only client with NO secret CANNOT
  be used as the MCP connector on External ID.** External ID's token endpoint does **not**
  advertise `token_endpoint_auth_method=none` (its `token_endpoint_auth_methods_supported` =
  `client_secret_post`, `client_secret_basic`, `private_key_jwt`, `self_signed_tls_client_auth`).
  A public PKCE client reaches the authorize step fine but **fails the code→token exchange**.
  The MCP/Claude connector client MUST be a **confidential `web` client WITH a secret** (or
  cert) — `isFallbackPublicClient=false`. The user enters **both Client ID and Secret** in
  Claude's Advanced fields. (Supersedes the earlier "public PKCE is right" note.)

## Field-learned gotchas (MCP authorization-code flow — Claude connector ↔ External ID)

Hard-won during the inform-human connector bring-up (2026-06-05). The connector fails with
an *Entra Trace ID* but Claude shows no AADSTS code — get the real code by **reproducing the
authorize request with `curl`** and reading the 302 error redirect (the CIAM
`auditLogs/signIns` Graph endpoint is chronically Gateway-Timeout/503 — don't depend on it).

- **`AADSTS9010010 invalid_target` — "resource parameter doesn't match the requested scopes".**
  The MCP spec / RFC 8707 makes the client send `resource=<PRM .resource>` (e.g.
  `https://mcp.example.com`). Entra requires that `resource` value to identify the **same app**
  as the requested scope. If the API app's only `identifierUris` entry is `api://<appId>`,
  Entra can't resolve the https resource → instant fail **before any login UI**. **Fix: add the
  PRM `.resource` URL (and the connector URL, e.g. `…/mcp`) as additional `identifierUris` on
  the API app** (`PATCH /applications/{objectId}` `identifierUris`). CIAM accepts https
  identifier URIs with **no domain verification**. ⇒ This contradicts the strict
  `api-identifier-uri-form` rule above: an **MCP resource server needs BOTH** `api://<appId>`
  **and** its canonical https URL(s) as identifier URIs.
- **Token `aud` stays the bare appId GUID** (`<appId>`, not `api://<appId>` and not the https
  resource) regardless of which identifier URI drove the request — Entra normalizes audience to
  the appId. So the resource server validates `aud == <appId>` (the GUID). The
  `auth-audience-matches-appiduri` rule is an oversimplification: PRM `.resource` is the https
  URL, the scope prefix is `api://<appId>`, but the **validated `aud` is the bare GUID**.
- **Identity scoping is per-`oid`, and the connector login MUST be the same human/`oid` as the
  portal login.** Authorizations (the anti-spam allowlist) are partitioned by the caller's `oid`.
  If a user signs into the management portal as `alice@x` but adds the MCP connector as
  `alice@y` (a *different* External ID user → different `oid`), the connector's calls see an
  empty allowlist and every send is refused — **correct behavior, not a bug.** Surface the
  signed-in account email in both the portal header and tool-refusal messages so this is obvious.

## Scaling gotcha: no DCR ⇒ shared static client (and the fix)

- **External ID exposes NO Dynamic Client Registration** (`registration_endpoint` absent from
  its OAuth metadata) and won't accept a public client (no `none` token-auth). The only thing
  that works today is **one shared confidential client whose Client ID + Secret every user
  pastes into Claude**. Functionally safe for isolation (each user still authenticates + consents
  individually; identity/allowlist are per-`oid`; a leaked secret can't read or send as another
  user), **but** a secret handed to every user is not a real secret: it can't be rotated without
  breaking everyone, it expires (≤2y → mass reconfig), and anyone holding it can impersonate the
  *client* against your tenant. **Acceptable for a trusted handful / demo; not for public launch.**
- **Solution = put a DCR-speaking façade in front of External ID** (External ID keeps doing human
  auth). Cheapest→fullest: (1) **static-DCR shim** — an endpoint advertising a `registration_endpoint`
  whose `POST /register` (RFC 7591) hands back your one pre-provisioned client **server-side**, so
  users add only the URL and never see a secret; `/authorize` + `/token` still point at ciamlogin.
  (2) **per-client DCR via Graph** — `/register` mints a distinct Entra app per client (real
  isolation; cost: Graph perms, throttling, app-sprawl lifecycle). (3) **thin self-hosted AS** that
  natively supports DCR + PKCE + public clients and federates to External ID as the upstream OIDC
  IdP — the clean multi-user end-state. Ship (1) before going past a trusted group.
- **Two MCP-client OAuth archetypes — design the façade for the UNION (field-observed across
  Claude + Grok, 2026-06-06).** Clients fall into two camps needing *different* secret-removal
  mechanisms: **(A) discovery + DCR** (Claude — add URL only, auto-discovers PRM/AS metadata,
  self-registers via `registration_endpoint`) → fixed by a **static-DCR shim**; **(B) manual
  config + public PKCE** (Grok — user types Client ID + authorize/token endpoints + a
  `Token Auth Method` selector whose *recommended* value is `none (PKCE only)`) → fixed by a
  **token-injecting proxy** (accept the public-PKCE `none` request, add the `client_secret`
  server-side when calling External ID's `/token`). External ID serves **neither** cleanly (no
  DCR; token endpoint has no `none`), so against External ID *both* archetypes are forced onto a
  pasted shared secret today. **The single thing that satisfies both is the Option-3 AS:** it
  must serve **PRM + AS metadata + DCR + public-PKCE (`none`) + confidential** at once. Make
  **"a public PKCE client with `token_auth_method=none` connects with no secret"** a first-class
  acceptance test — it's the button users reach for, and the ecosystem default is trending to it.
  A bespoke DCR-shim *plus* a bespoke token-proxy is Option 3 assembled piecemeal; once you need
  both, the real AS is usually less work than maintaining two half-façades.
- **Near-term reality:** manual-config clients (Grok) connect to External ID **today** with
  `client_secret_post` (or `client_secret_basic` — both in External ID's
  `token_endpoint_auth_methods_supported`) + the shared secret + explicit `…/oauth2/v2.0/authorize`
  & `/token` endpoints. Each such client uses its **own redirect URI** (e.g. `https://grok.com/…`)
  → add it to the connector app's `web.redirectUris` or you get `AADSTS500113` redirect mismatch.
- **Never mutate tenant state while a human is mid-portal-operation.** Deleting a flow while the
  operator was mid-"OK" raced and orphaned the apps. Coordinate; don't race the portal.
