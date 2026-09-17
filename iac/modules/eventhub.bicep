param env string
param location string
param namePrefix string
param tags object
param peSubnetId string
param vnetId string
param captureStorageAccountId string

var nsName = 'evhns-${namePrefix}-${env}'
var isProd = env == 'prod'

resource ns 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: nsName
  location: location
  tags: tags
  sku: {
    name: isProd ? 'Premium' : 'Standard'
    tier: isProd ? 'Premium' : 'Standard'
    capacity: isProd ? 2 : 1
  }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: isProd ? 'Disabled' : 'Enabled'
    zoneRedundant: isProd
  }
}

resource hub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: ns
  name: 'inventory-events'
  properties: {
    partitionCount: 8
    messageRetentionInDays: 7
    captureDescription: {
      enabled: true
      encoding: 'Avro'
      intervalInSeconds: 300
      sizeLimitInBytes: 314572800
      destination: {
        name: 'EventHubArchive.AzureBlockBlob'
        properties: {
          storageAccountResourceId: captureStorageAccountId
          blobContainer: 'eventhub-capture'
          archiveNameFormat: '{Namespace}/{EventHub}/{PartitionId}/{Year}/{Month}/{Day}/{Hour}/{Minute}/{Second}'
        }
      }
    }
  }
}

resource cgD365 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: hub
  name: 'cg-d365'
}

resource cgDatahub 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: hub
  name: 'cg-datahub'
}

// Schema registry group for CDM envelope enforcement
resource schemaGroup 'Microsoft.EventHub/namespaces/schemagroups@2024-01-01' = {
  parent: ns
  name: 'inventory-cdm'
  properties: {
    schemaCompatibility: 'Backward'
    schemaType: 'Json'
  }
}

resource pe 'Microsoft.Network/privateEndpoints@2023-09-01' = if (isProd) {
  name: 'pe-${nsName}'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'evh'
        properties: {
          privateLinkServiceId: ns.id
          groupIds: ['namespace']
        }
      }
    ]
  }
}

output namespaceName string = ns.name
output namespaceFqdn string = '${ns.name}.servicebus.windows.net'
output eventHubName string = hub.name
