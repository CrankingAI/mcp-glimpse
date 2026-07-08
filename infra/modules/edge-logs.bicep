// =============================================================================
// edge-logs.bicep — Azure-side plumbing for the Cloudflare edge log
// (docs/edge.md): DCE + DCR + the EdgeHits_CL custom table with 10-day
// retention baked in (the EFF-DNT window — raw IP/UA live here and nowhere
// else, then auto-purge).
//
// AVM note: avm/res/insights/data-collection-endpoint and
// avm/res/insights/data-collection-rule exist on the public registry; the raw
// resources are used here because the stream declaration IS the load-bearing
// content (columns must match apps/edge/src/record.ts:toLogAnalytics). Swap
// to AVM at adoption if preferred — pin/verify at https://aka.ms/avm.
//
// The Worker authenticates with Entra client credentials (no managed identity
// off-Azure): pass that app registration's service-principal objectId as
// workerPrincipalId to grant Monitoring Metrics Publisher on the DCR.
// =============================================================================

@description('Azure region for the DCE/DCR.')
param location string

@description('Workload / project name (CAF token, lowercase).')
param project string

@description('Environment short name (CAF token, e.g. run).')
param env string

@description('Tags applied to all resources.')
param tags object

@description('Resource ID of the Log Analytics workspace (shared module output).')
param workspaceResourceId string

@description('Service-principal objectId of the edge Worker app registration. Empty = skip the role assignment (grant later).')
param workerPrincipalId string = ''

var workspaceName = last(split(workspaceResourceId, '/'))
var streamName = 'Custom-EdgeHits_CL'

// Columns mirror apps/edge/src/record.ts:toLogAnalytics — keep in sync.
var edgeHitsColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'Path', type: 'string' }
  { name: 'Method', type: 'string' }
  { name: 'Status', type: 'int' }
  { name: 'UserAgent', type: 'string' }
  { name: 'Ip', type: 'string' }
  { name: 'Country', type: 'string' }
  { name: 'Region', type: 'string' }
  { name: 'City', type: 'string' }
  { name: 'Colo', type: 'string' }
  { name: 'Verified', type: 'boolean' }
  { name: 'BotName', type: 'string' }
  { name: 'Score', type: 'real' }
]

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

// 10-day retention is the point — do not raise it without revisiting the DNT
// posture (docs/edge.md, docs/site-conventions.md#well-knowndnt-policytxt).
resource edgeHitsTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: workspace
  name: 'EdgeHits_CL'
  properties: {
    retentionInDays: 10
    totalRetentionInDays: 10
    schema: {
      name: 'EdgeHits_CL'
      columns: edgeHitsColumns
    }
  }
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: 'dce-${project}-${env}'
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled' // the CF Worker calls in from the edge
    }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-edge-${project}-${env}'
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      '${streamName}': {
        columns: edgeHitsColumns
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'law'
          workspaceResourceId: workspaceResourceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [streamName]
        destinations: ['law']
        transformKql: 'source'
        outputStream: streamName
      }
    ]
  }
  dependsOn: [edgeHitsTable]
}

// Monitoring Metrics Publisher (3913510d-42f4-4e42-8a64-420c390055eb) on the
// DCR — the only role the Worker's app registration holds.
resource workerPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(workerPrincipalId)) {
  name: guid(dcr.id, workerPrincipalId, 'monitoring-metrics-publisher')
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '3913510d-42f4-4e42-8a64-420c390055eb'
    )
    principalId: workerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output dceIngestionEndpoint string = dce.properties.logsIngestion.endpoint
output dcrImmutableId string = dcr.properties.immutableId
output streamName string = streamName
