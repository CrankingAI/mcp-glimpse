// =============================================================================
// glimpse — IaC entrypoint (AVM-based starter — naming: docs/deployment.md;
// persistence locks: docs/persistence.md)
// -----------------------------------------------------------------------------
// Subscription-scoped: creates the resource group, then a single shared module
// that provisions cross-cutting platform resources via Azure Verified Modules
// (br/public:avm/res/...). This is a STARTER — backend host (Functions / ACA,
// plus an MCP interface) and persistence are added per repo from the chosen rule.
//
// AVM module versions below are realistic and recent; pin/verify against the
// public registry (https://aka.ms/avm) when you adopt the kit, then bump
// deliberately. AVM paths are stable; only the :version tag moves.
//
// Naming (CAF, tokenized — docs/deployment.md):
//   rg-glimpse-prod, appi-/appcs-/id-glimpse-prod
//   kv-glimpse-prod and stglimpseprod get a deterministic
//   uniqueString suffix to satisfy Azure's GLOBAL-namespace requirement.
// =============================================================================

targetScope = 'subscription'

// ---- Parameters -------------------------------------------------------------

@description('Azure region for all resources.')
param location string

@minLength(2)
@maxLength(20)
@description('Workload / project name (CAF PROJECT token, lowercase).')
param project string

@minLength(2)
@maxLength(10)
@description('Environment short name (CAF ENV token, e.g. prod).')
param env string

@description('Tags applied to the resource group and all resources.')
param tags object = {
  project: project
  env: env
  'managed-by': 'azd'
}

@description('Full container image reference for the MCP server (empty on first provision).')
param containerImage string = ''

@description('Custom domain for the MCP host (empty = default ACA FQDN only until DNS/cert are set).')
param mcpCustomDomain string = ''

@description('Login server of the fleet-shared registry (creffaz, EffAz-Ops). AcrPull for the app MI is granted cross-subscription by devp-azure-ops/infra/container-platform (F-0008, 2026-08-08).')
param sharedContainerRegistryLoginServer string = 'creffaz.azurecr.io'

// ---- Derived names ----------------------------------------------------------

var rgName = 'rg-${project}-${env}'

// Deterministic, per-RG suffix for globally-unique namespaces (KV + Storage).
// uniqueString is stable for a given RG id, so names are idempotent across runs.
var globalSuffix = uniqueString(subscription().id, rgName)

// ---- Resource group ---------------------------------------------------------

resource rg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: rgName
  location: location
  tags: tags
}

// ---- Shared cross-cutting platform module -----------------------------------

module shared 'modules/shared.bicep' = {
  scope: rg
  name: 'shared-${env}'
  params: {
    location: location
    project: project
    env: env
    tags: tags
    globalSuffix: globalSuffix
  }
}

// ---- MCP server on Azure Container Apps -------------------------------------
// Only deploy the app once an image reference is supplied (containerImage). The first
// `az deployment` may pass a placeholder; the tag-push pipeline passes the real image.

module aca 'app/aca.bicep' = if (!empty(containerImage)) {
  scope: rg
  name: 'aca-${env}'
  params: {
    location: location
    tags: tags
    project: project
    env: env
    containerImage: containerImage
    managedIdentityResourceId: shared.outputs.managedIdentityResourceId
    managedIdentityClientId: shared.outputs.managedIdentityClientId
    managedIdentityPrincipalId: shared.outputs.managedIdentityPrincipalId
    storageAccountName: shared.outputs.storageAccountName
    logAnalyticsWorkspaceId: shared.outputs.logAnalyticsWorkspaceId
    appInsightsConnectionString: shared.outputs.appInsightsConnectionString
    acrLoginServer: sharedContainerRegistryLoginServer
    customDomain: mcpCustomDomain
  }
}

// AcrPull on the shared registry is cross-subscription and therefore granted
// by the registry's owner (devp-azure-ops container-platform), not from here.

// BEGIN edge-logs (removed by seed-init.sh --edge none)
// ---- Edge -------------------------------------------------------------------
// The public edge is Cloudflare (proxied), not an Azure resource — zone config
// is scripts/cf-zone-init.sh; the edge Worker is apps/edge/. The Azure-side
// log plumbing (DCE + DCR + EdgeHits_CL, 10-day retention) is wired below.
// See docs/edge.md.

@description('Service-principal objectId of the edge Worker app registration (optional).')
param edgeWorkerPrincipalId string = ''

module edgeLogs 'modules/edge-logs.bicep' = {
  scope: rg
  name: 'edge-logs-${env}'
  params: {
    location: location
    project: project
    env: env
    tags: tags
    workspaceResourceId: shared.outputs.logAnalyticsWorkspaceId
    workerPrincipalId: edgeWorkerPrincipalId
  }
}

// Feed these to the Worker: wrangler secret put AZURE_DCE_ENDPOINT / _DCR_ID
// / _STREAM (see apps/edge/wrangler.jsonc).
output AZURE_EDGE_DCE_ENDPOINT string = edgeLogs.outputs.dceIngestionEndpoint
output AZURE_EDGE_DCR_IMMUTABLE_ID string = edgeLogs.outputs.dcrImmutableId
output AZURE_EDGE_STREAM string = edgeLogs.outputs.streamName
// END edge-logs

// ---- Outputs (azd reads AZURE_* names) --------------------------------------

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location

output APPLICATIONINSIGHTS_CONNECTION_STRING string = shared.outputs.appInsightsConnectionString
output AZURE_LOG_ANALYTICS_WORKSPACE_ID string = shared.outputs.logAnalyticsWorkspaceId
output AZURE_KEY_VAULT_NAME string = shared.outputs.keyVaultName
output AZURE_KEY_VAULT_URI string = shared.outputs.keyVaultUri
output AZURE_APP_CONFIG_NAME string = shared.outputs.appConfigName
output AZURE_APP_CONFIG_ENDPOINT string = shared.outputs.appConfigEndpoint
output AZURE_CLIENT_ID string = shared.outputs.managedIdentityClientId
output AZURE_MANAGED_IDENTITY_ID string = shared.outputs.managedIdentityResourceId
output AZURE_STORAGE_ACCOUNT_NAME string = shared.outputs.storageAccountName

output MCP_FQDN string = !empty(containerImage) ? aca.outputs.fqdn : ''
output MCP_CUSTOM_DOMAIN_VERIFICATION_ID string = !empty(containerImage) ? aca.outputs.customDomainVerificationId : ''
output MCP_DEFAULT_DOMAIN string = !empty(containerImage) ? aca.outputs.defaultDomain : ''
