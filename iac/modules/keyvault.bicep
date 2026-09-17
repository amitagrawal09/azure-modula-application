param env string
param location string
param namePrefix string
param tags object
param peSubnetId string
param vnetId string

var isProd = env == 'prod'

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${namePrefix}-${env}'
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    publicNetworkAccess: isProd ? 'Disabled' : 'Enabled'
  }
}

resource pe 'Microsoft.Network/privateEndpoints@2023-09-01' = if (isProd) {
  name: 'pe-kv-${namePrefix}-${env}'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'kv'
        properties: {
          privateLinkServiceId: kv.id
          groupIds: ['vault']
        }
      }
    ]
  }
}

output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri
