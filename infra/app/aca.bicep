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
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
    // A non-VNet managed environment is publicly reachable by default (the AVM wrapper is what
    // defaults publicNetworkAccess to Disabled). The real boundary is the Cloudflare edge + the
    // app rate limiter; per-app ingress.external controls exposure.
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
        customDomains: empty(customDomain) ? [] : [
          {
            name: customDomain
            bindingType: 'Auto'
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
              initialDelaySeconds: 8
              periodSeconds: 20
              failureThreshold: 6
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
