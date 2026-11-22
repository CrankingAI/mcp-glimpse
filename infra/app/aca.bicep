// infra/app/aca.bicep — the mcp-glimpse MCP server on Azure Container Apps.
//
// Scope: the project resource group (rg-glimpse-prod). Consumes the shared user-assigned
// managed identity + storage + Log Analytics; pulls its image from a shared ACR (AcrPull is
// granted cross-RG in infra/app/acr-pull.bicep). Bakes in every ACA "failed only live" fix:
// publicNetworkAccess Enabled, registries+pull identity, AZURE_CLIENT_ID in the container env,
// MCP_ALLOWED_HOSTS set, scale 0..1 with sticky sessions (session-bearing HTTP; F-0009),
// and custom domains declared in IaC (bindingType Auto).

param location string
param tags object
param project string
param env string

@description('Full container image reference, e.g. crankingaiacr.azurecr.io/mcp-glimpse:0.1.0')
param containerImage string

param managedIdentityResourceId string
param managedIdentityClientId string
param managedIdentityPrincipalId string
param storageAccountName string
param logAnalyticsWorkspaceId string
param appInsightsConnectionString string

@description('ACR login server, e.g. crankingaiacr.azurecr.io')
param acrLoginServer string

@description('Custom domain to bind (empty = default ACA FQDN only). Requires the cert + DNS dance.')
param customDomain string = ''

@description('Name of the environment managed certificate already issued for customDomain (empty = bootstrap: bind with Auto and let scripts/cf-domain-bind.sh issue it). Once issued, set this so IaC declares the live SniEnabled binding instead of reverting it.')
param customDomainCertificateName string = ''

var appName = 'app-${project}-${env}'
var envName = 'cae-${project}-${env}'
var tableEndpoint = 'https://${storageAccountName}.table.${environment().suffixes.storage}'
var storageTableDataContributor = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
)

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: last(split(logAnalyticsWorkspaceId, '/'))
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: envName
  location: location
  tags: tags
  properties: {
    // 'azure-monitor' (routed by the diagnostic setting below), NOT 'log-analytics': the latter
    // writes with the workspace shared key, and the workspace has local auth disabled — so every
    // console line was silently rejected (zero rows, Aug–Nov 2026). Diagnostic settings need no key.
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    // A non-VNet managed environment is publicly reachable by default (the AVM wrapper is what
    // defaults publicNetworkAccess to Disabled). The real boundary is the Cloudflare edge + the
    // app rate limiter; per-app ingress.external controls exposure.
  }
}

// Console + system logs -> the shared workspace (resource-specific ContainerApp* tables).
// ContainerAppHTTPLogs is deliberately OFF: ingress access logs carry the raw client IP + UA, and
// this workspace retains 30 days — raw IP/UA may live only in the 10-day edge log (docs/edge.md).
resource acaEnvLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'logs-to-${law.name}'
  scope: acaEnv
  properties: {
    workspaceId: law.id
    logs: [
      { category: 'ContainerAppConsoleLogs', enabled: true }
      { category: 'ContainerAppSystemLogs', enabled: true }
    ]
  }
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: union(tags, { 'azd-service-name': 'mcp' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityResourceId}': {}
    }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        // Session-bearing Streamable HTTP: pin a session to its replica.
        stickySessions: {
          affinity: 'sticky'
        }
        // Steady state = the live binding: SniEnabled + the issued managed cert. 'Auto' is the
        // bootstrap form only — applying it over a bound domain drops certificateId (what-if,
        // 2026-11-22), so never deploy it once the cert exists.
        customDomains: empty(customDomain) ? [] : [
          empty(customDomainCertificateName)
            ? {
                name: customDomain
                bindingType: 'Auto'
              }
            : {
                name: customDomain
                bindingType: 'SniEnabled'
                certificateId: '${acaEnv.id}/managedCertificates/${customDomainCertificateName}'
              }
        ]
      }
      registries: [
        {
          server: acrLoginServer
          identity: managedIdentityResourceId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'mcp-glimpse'
          image: containerImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'PORT', value: '8080' }
            { name: 'HOST', value: '0.0.0.0' }
            // DNS-rebinding Host allowlist for the public FQDN (else 421). Include both the
            // custom domain (when set) and the default ACA FQDN via '*' fallback at the edge.
            { name: 'MCP_ALLOWED_HOSTS', value: empty(customDomain) ? '*' : '${customDomain},${appName}.${acaEnv.properties.defaultDomain}' }
            // A user-assigned MI with DefaultAzureCredential MUST get AZURE_CLIENT_ID or the
            // Azure path fails invisibly (health stays green).
            { name: 'AZURE_CLIENT_ID', value: managedIdentityClientId }
            { name: 'GLIMPSE_MANAGED_IDENTITY_CLIENT_ID', value: managedIdentityClientId }
            { name: 'GLIMPSE_TABLE_URI', value: tableEndpoint }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
          ]
          // Scale-to-zero (F-0009) means every idle wake is a cold start, and ingress holds
          // requests until Readiness passes — so readiness polls fast. A 20s period cost up to
          // 20s per cold start (2026-11-22: queued requests hit ClientDisconnect waiting for it).
          // Liveness stays slow; it only needs to catch a wedged process.
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: '/livez', port: 8080 }
              initialDelaySeconds: 8
              periodSeconds: 20
            }
            {
              type: 'Readiness'
              httpGet: { path: '/readyz', port: 8080 }
              initialDelaySeconds: 1
              periodSeconds: 2
              timeoutSeconds: 2
              // 10 x 2s = 20s before pulling the only replica: Table Storage calls are sync on the
              // event loop and may stall a few seconds; that must not 503 the whole service.
              failureThreshold: 10
            }
          ]
        }
      ]
      scale: {
        // 0 per estate F-0009 (devp-azure-ops): max=1 gave no zero-downtime
        // benefit anyway; idle scale-down re-initializes MCP sessions on the
        // next request (acceptable cold-start for a free showcase endpoint).
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
}

// MI -> Storage Table Data Contributor (feedback + cards tables), same RG.
resource tableRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, managedIdentityPrincipalId, 'table-data-contributor')
  scope: storage
  properties: {
    roleDefinitionId: storageTableDataContributor
    principalId: managedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output fqdn string = app.properties.configuration.ingress.fqdn
output name string = app.name
output customDomainVerificationId string = app.properties.customDomainVerificationId
output defaultDomain string = acaEnv.properties.defaultDomain
