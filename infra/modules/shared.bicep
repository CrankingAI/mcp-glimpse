// =============================================================================
// glimpse — shared cross-cutting platform resources (resource-group scope)
// -----------------------------------------------------------------------------
// Provisioned via Azure Verified Modules (br/public:avm/res/...):
//   - Log Analytics workspace        (observability backplane, docs/observability.md)
//   - Application Insights component  (OTel -> Azure Monitor via ServiceDefaults)
//   - User-assigned managed identity  (passwordless auth, docs/security.md)
//   - Key Vault (RBAC authorization)  (no secrets in code, docs/security.md)
//   - App Configuration              (feature flags, docs/feature-flags.md)
//   - Storage account                (cheap/simple persistence option, docs/persistence.md)
//
// The managed identity is granted data-plane RBAC on Key Vault + App Config so
// the chosen backend host can resolve secrets/flags with DefaultAzureCredential.
// =============================================================================

@description('Azure region for all resources.')
param location string

@description('Workload / project name (CAF PROJECT token, lowercase).')
param project string

@description('Environment short name (CAF ENV token, e.g. prod).')
param env string

@description('Tags applied to all resources.')
param tags object

@description('Deterministic suffix for globally-unique namespaces (KV + Storage).')
param globalSuffix string

// ---- Derived names (CAF, docs/deployment.md) --------------------------------

var logAnalyticsName = 'log-${project}-${env}'
var appInsightsName = 'appi-${project}-${env}'
var managedIdentityName = 'id-${project}-${env}'
var appConfigName = 'appcs-${project}-${env}'

// Globally-unique namespaces keep the readable stem + a uniqueString tail.
// KV names: <= 24 chars, alphanumeric + hyphens. Storage: <= 24, alphanumeric.
var keyVaultName = take('kv-${project}-${env}-${globalSuffix}', 24)
var storageAccountName = take(toLower('st${project}${env}${globalSuffix}'), 24)

// Built-in role definition IDs (data-plane RBAC).
var roleKeyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var roleAppConfigDataReader = '516239f1-63e1-4d78-a4de-a74fb236a071'

// ---- Log Analytics workspace ------------------------------------------------

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.11.1' = {
  name: 'log-analytics'
  params: {
    name: logAnalyticsName
    location: location
    tags: tags
    // 30-day retention is a sane idle-cost default; tune via the operational
    // to-do list (operational-readiness skill, docs/operations.md).
    dataRetention: 30
  }
}

// ---- Application Insights (workspace-based) ---------------------------------

module appInsights 'br/public:avm/res/insights/component:0.6.0' = {
  name: 'app-insights'
  params: {
    name: appInsightsName
    location: location
    tags: tags
    workspaceResourceId: logAnalytics.outputs.resourceId
    applicationType: 'web'
    // IP -> geo is privacy-preserving and the raw IP is masked downstream by the
    // OTel ClientIpEnrichingProcessor (docs/observability.md); nothing to set here.
    disableIpMasking: false
  }
}

// ---- User-assigned managed identity -----------------------------------------

module managedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.1' = {
  name: 'managed-identity'
  params: {
    name: managedIdentityName
    location: location
    tags: tags
  }
}

// ---- Key Vault (RBAC authorization, no access policies) ---------------------

module keyVault 'br/public:avm/res/key-vault/vault:0.12.1' = {
  name: 'key-vault'
  params: {
    name: keyVaultName
    location: location
    tags: tags
    // RBAC over the legacy access-policy model (docs/security.md).
    enableRbacAuthorization: true
    enablePurgeProtection: true
    sku: 'standard'
    // Grant the workload identity read access to secrets at provision time.
    roleAssignments: [
      {
        principalId: managedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: roleKeyVaultSecretsUser
      }
    ]
  }
}

// ---- App Configuration (feature flags) --------------------------------------

module appConfig 'br/public:avm/res/app-configuration/configuration-store:0.7.0' = {
  name: 'app-config'
  params: {
    name: appConfigName
    location: location
    tags: tags
    sku: 'Standard'
    // Disable local auth -> identity-only (passwordless) access.
    disableLocalAuth: true
    roleAssignments: [
      {
        principalId: managedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: roleAppConfigDataReader
      }
    ]
  }
}

// ---- Storage account (cheap/simple persistence option, docs/persistence.md) -

module storage 'br/public:avm/res/storage/storage-account:0.20.0' = {
  name: 'storage'
  params: {
    name: storageAccountName
    location: location
    tags: tags
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    // Passwordless: no shared keys; reach blobs/tables via the managed identity.
    allowSharedKeyAccess: false
    // The AVM storage module defaults networkAcls.defaultAction to 'Deny' when
    // the param is omitted. With no VNet in the kit topology, that silently
    // makes every managed-identity Table/Blob call fail with a 403
    // AuthorizationFailure that reads EXACTLY like an RBAC problem (fleet
    // finding — docs/backlog.md §11a). Set the posture explicitly: public
    // networking on, but the data plane stays Entra + RBAC only (shared keys
    // are off above). Private endpoints are the ops upgrade path when the data
    // warrants VNet isolation — see docs/persistence.md.
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// ---- Outputs ----------------------------------------------------------------

output logAnalyticsWorkspaceId string = logAnalytics.outputs.resourceId
output appInsightsConnectionString string = appInsights.outputs.connectionString
output keyVaultName string = keyVault.outputs.name
output keyVaultUri string = keyVault.outputs.uri
output appConfigName string = appConfig.outputs.name
output appConfigEndpoint string = appConfig.outputs.endpoint
output managedIdentityClientId string = managedIdentity.outputs.clientId
output managedIdentityResourceId string = managedIdentity.outputs.resourceId
output storageAccountName string = storage.outputs.name
