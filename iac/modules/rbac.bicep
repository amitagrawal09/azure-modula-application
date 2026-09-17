param eventHubNamespaceName string
param keyVaultName string
param storageAccountName string
param modulaAdapterPrincipalId string
param d365AdapterPrincipalId string
param datahubAdapterPrincipalId string

// Built-in role definition IDs
var roles = {
  eventHubsDataSender:   '2b629674-e913-4c01-ae53-ef4638d8f975'
  eventHubsDataReceiver: 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'
  keyVaultSecretsUser:   '4633458b-17de-408a-b874-0445c86b69e6'
  storageBlobDataContrib:'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}

resource evhns 'Microsoft.EventHub/namespaces@2024-01-01' existing = { name: eventHubNamespaceName }
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = { name: keyVaultName }
resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: storageAccountName }

// Modula adapter: send to Event Hub
resource raSend 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(evhns.id, modulaAdapterPrincipalId, 'send')
  scope: evhns
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.eventHubsDataSender)
    principalId: modulaAdapterPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Consumers: receive from Event Hub
resource raRecv 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for p in [d365AdapterPrincipalId, datahubAdapterPrincipalId]: {
  name: guid(evhns.id, p, 'recv')
  scope: evhns
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.eventHubsDataReceiver)
    principalId: p
    principalType: 'ServicePrincipal'
  }
}]

// All adapters: Key Vault secrets + checkpoint/bronze storage
resource raKv 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for p in [modulaAdapterPrincipalId, d365AdapterPrincipalId, datahubAdapterPrincipalId]: {
  name: guid(kv.id, p, 'kvsecrets')
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
    principalId: p
    principalType: 'ServicePrincipal'
  }
}]

resource raSa 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for p in [modulaAdapterPrincipalId, d365AdapterPrincipalId, datahubAdapterPrincipalId]: {
  name: guid(sa.id, p, 'blob')
  scope: sa
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContrib)
    principalId: p
    principalType: 'ServicePrincipal'
  }
}]
