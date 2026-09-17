param env string
param location string
param namePrefix string
param tags object
param peSubnetId string
param vnetId string

var isProd = env == 'prod'

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${namePrefix}${env}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: isProd ? 'Standard_ZRS' : 'Standard_LRS' }
  properties: {
    isHnsEnabled: true // ADLS Gen2 — bronze landing + checkpoints + capture
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: isProd ? 'Disabled' : 'Enabled'
  }
}

resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: sa
  name: 'default'
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [for c in [
  'eventhub-capture'
  'checkpoints'
  'bronze'
  'quarantine'
]: {
  parent: blobSvc
  name: c
}]

resource pe 'Microsoft.Network/privateEndpoints@2023-09-01' = if (isProd) {
  name: 'pe-st${namePrefix}${env}'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'dfs'
        properties: {
          privateLinkServiceId: sa.id
          groupIds: ['dfs']
        }
      }
    ]
  }
}

output storageAccountId string = sa.id
output storageAccountName string = sa.name
