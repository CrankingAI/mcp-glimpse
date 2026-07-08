# Deployment

`azd` + Bicep (AVM modules) + GitHub Actions on a **tag push**. One environment,
azd env `CrankingAI-prod` (default `EffAz-prod`). Staging is a slot/revision
*inside* it, never a separate build. **Promotion = build once, promote the same artifact** — never
rebuild per stage.

## Pipeline shape

- **Trigger:** push a `v*` tag (e.g. `v1.4.0`). Tag → build → deploy. Branch
  pushes run CI gates only (build + test + lint); they do not deploy.
- **Provision:** `azd provision` applies Bicep. Infra is AVM (Azure Verified
  Modules) wherever a module exists — pinned versions, no hand-rolled resource
  bodies for things AVM already covers.
- **Deploy:** `azd deploy` ships the built artifact to the platform.
- **Edge deploy:** `wrangler deploy` ships `apps/edge/` after `azd deploy`
  (via `cloudflare/wrangler-action`; CF tokens in GH secrets — see
  [edge](edge.md)).
- **Verify:** smoke test against `/readyz` before traffic is shifted.

```text
v* tag push
  → build (single artifact, stamped from VERSION)
  → azd provision (Bicep / AVM)
  → azd deploy to staging slot / inactive revision / SWA preview
  → smoke test /readyz on the staging target
  → promote: slot swap / revision traffic shift / SWA env promote
  → smoke test /readyz on production target
```

The tag-to-bits alignment (the deployed `/version` must match the pushed tag) is
enforced by the **tag-version-bits-alignment** skill. `VERSION` is the single
source of truth — see [versioning](versioning.md).

## Naming

Tokenized CAF scheme (greppable). Defaults: ORG=`EffAz`, ENV=`prod`;
PROJECT is the workload name.

- **azd env:** `CrankingAI-prod` (default `EffAz-prod`) — one name shared by the
  azd environment and the resource-name suffix. (Until 2026-07-05 the azd env
  was a special-cased capital-R `EffAz-Run`; field use showed the two-name
  scheme invited conflation, so the ENV token is now the single source.)
- **Subscription:** the azd env targets the **`EffAz-Prod`** subscription by
  default (set `AZURE_SUBSCRIPTION_ID` when creating the azd env);
  a different subscription is a per-repo operator choice, recorded in the repo.
- **Resource group:** `rg-glimpse-prod`
- **Resources:** `app-`/`func-`/`appi-`/`appcs-glimpse-prod`
- **Globally-unique names:** Key Vault (`kv-glimpse-prod`) and Storage
  (`stglimpseprod`) append a deterministic `uniqueString(resourceGroup().id)`
  suffix in Bicep — purely to satisfy Azure's global-namespace requirement, not a
  style choice.

## Single environment, in-place staging

There is one named environment. Staging happens inside it, per backend:

| Backend | Staging mechanism | Promotion |
|---|---|---|
| Container Apps | new **revision**, 0% traffic | **traffic split** shift to 100% |
| Functions | deployment slot | slot swap |
| Static Web Apps | **preview environment** | promote preview → production |

Additional named environments are optional and added later. The default keeps one.

## Build once, promote the same artifact

The artifact built at tag time is the artifact that reaches production. The
staging slot / inactive revision / preview env runs **those exact bits**;
promotion is a swap or traffic shift, never a rebuild. Rebuilding per stage breaks
the guarantee that what you smoke-tested is what serves traffic.

For Container Apps, the zero-downtime promotion contract (revision suffixes,
single-revision vs multiple-revision mode, traffic weights) is owned by the
**zero-downtime-aca-contract** skill. Do not hand-design revision/traffic logic —
follow that contract.

## Smoke tests

Before shifting traffic, smoke-test the staging target; after shifting, smoke-test
production:

- `/readyz` returns `200` (the gate — see [health-checks](health-checks.md)).
- `/version` matches the pushed tag.
- One or two critical-path requests succeed.

A non-`200` `/readyz` aborts the promotion; traffic stays on the previous
slot/revision. `/readyz` returning `200` post-deploy is part of the agent
definition of done.

For Container Apps, **verify the deploy actually landed** — revision state,
deployed config, ingress posture, and the App Insights deploy-window query — with
the **aca-deploy-verification** skill. It answers "did this actually deploy?" and
"are the bits matching the tag?" rather than trusting the pipeline exit code.

## Custom domains

- Bind the custom domain at the origin (ACA custom domain + managed cert, or
  SWA custom domain), then front it with the Cloudflare proxied edge —
  `scripts/cf-domain-bind.sh` runs the grey-cloud → validate → orange-cloud
  sequence end-to-end. See [edge](edge.md).
- **For ACA, declare domains IN the applied IaC** (`ingress.customDomains`,
  `bindingType: 'Auto'`, no cert pin) so provision/deploy are idempotent —
  out-of-band `az containerapp hostname add/bind` in a pipeline is stripped by
  the next apply. Details and the bicep snippet:
  [backend-container-apps](../rules/backend-container-apps.md#custom-domains).
- Deploy contract: order the DNS reconcile **before the first apply that
  declares the domains** — `azd provision` in the kit's `infra/` shape,
  `azd deploy` in an Aspire AppHost shape (ARM validates the `asuid` TXT at
  the containerApp PUT) — then verify → smoke. A hostname-bind script is
  one-time fresh-env bootstrap + break-glass, not a pipeline dependency, and
  must count `bindingType 'Auto'` as bound.
- `www`→apex redirect and well-known files are covered in
  [site-conventions](site-conventions.md).
- TLS certs are platform-managed (auto-renew); no cert material in the repo.

## Preflight before any deploy

Run `./scripts/preflight.sh` at the **start** of any deploy/seed/domain-bind
operation. It exercises the real *capability* of each credential in play — not
just login status — so a stuck credential fails in seconds instead of 30
minutes into a provision. It catches the false-greens the fleet hit: `azd auth
login --check-status` reporting "Logged in" while principal resolution was
broken, and a Cloudflare token passing `verify` while lacking the zone scope it
needed (docs/backlog.md §11b). Skips any tool/credential not present; exits
non-zero on the first real failure with the exact fix.

## az-based fallback deploy (when azd auth is uncooperative)

If `azd provision` / `azd up` fails at `fetching current principal id … failed
to resolve user access to subscription` even though `az account show` /
`get-access-token` work (a repeatable azd trap — docs/backlog.md §11d), deploy
via `az` directly and do not let azd block the ship:

```text
az deployment sub create --location <r> --template-file infra/main.bicep --parameters ...
az acr build ...            # or docker build + push to the (shared) registry
az containerapp update --image <registry>/<repo>:<tag> ...
npx @azure/static-web-apps-cli deploy apps/web/dist --deployment-token <tok> --env production
```

Note the paired footgun: **every `azd provision` reverts the container app to the
bicep placeholder image** unless the real image is carried as an azd-env
parameter — re-run the `az containerapp update --image` step after any provision.

## First-time setup

Use the **setup-deploy** skill for first-time wiring: the GitHub Actions workflow,
the OIDC federated-credential trust (no stored Azure secret — managed identity /
workload identity federation; the Cloudflare leg's scoped API tokens are the
documented exception, see [security](security.md)), the azd environment, and the
tag-push trigger. Do not hand-roll the deploy workflow.

## Related

- [security](security.md) — managed identity, Key Vault refs, no secrets in CI.
- [operations](operations.md) — the per-environment operational to-do list created
  with the environment.
- [observability](observability.md) — the `/readyz` availability test + alerting
  baseline.
