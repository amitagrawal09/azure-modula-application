// main.bicep — Modula <-> D365 <-> DataHub integration platform
// Deploy: az deployment sub create -l eastus2 -f main.bicep -p env=dev
targetScope = 'subscription'

@allowed(['dev', 'test', 'prod'])
param env string = 'dev'
param location string = 'eastus2'
param namePrefix string = 'modint'

var rgName = 'rg-${namePrefix}-${env}'
var tags = {
  workload: 'modula-integration'
  environment: env
  owner: 'data-ai-architecture'
  costCenter: 'integration'
}

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: rgName
  location: location
  tags: tags
}

module network 'modules/network.bicep' = {
  scope: rg
  name: 'network'
  params: { env: env, location: location, namePrefix: namePrefix, tags: tags }
}

module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: { env: env, location: location, namePrefix: namePrefix, tags: tags }
}

module keyvault 'modules/keyvault.bicep' = {
  scope: rg
  name: 'keyvault'
  params: {
    env: env
    location: location
    namePrefix: namePrefix
    tags: tags
    peSubnetId: network.outputs.peSubnetId
    vnetId: network.outputs.vnetId
  }
}

module eventhub 'modules/eventhub.bicep' = {
  scope: rg
  name: 'eventhub'
  params: {
    env: env
    location: location
    namePrefix: namePrefix
    tags: tags
    peSubnetId: network.outputs.peSubnetId
    vnetId: network.outputs.vnetId
    captureStorageAccountId: storage.outputs.storageAccountId
  }
}

module servicebus 'modules/servicebus.bicep' = {
  scope: rg
  name: 'servicebus'
  params: { env: env, location: location, namePrefix: namePrefix, tags: tags }
}

module storage 'modules/storage.bicep' = {
  scope: rg
  name: 'storage'
  params: {
    env: env
    location: location
    namePrefix: namePrefix
    tags: tags
    peSubnetId: network.outputs.peSubnetId
    vnetId: network.outputs.vnetId
  }
}

module containerApps 'modules/containerapps.bicep' = {
  scope: rg
  name: 'containerApps'
  params: {
    env: env
    location: location
    namePrefix: namePrefix
    tags: tags
    infraSubnetId: network.outputs.acaSubnetId
    logAnalyticsCustomerId: monitoring.outputs.lawCustomerId
    logAnalyticsSharedKey: monitoring.outputs.lawSharedKey
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    eventHubNamespaceFqdn: eventhub.outputs.namespaceFqdn
    eventHubName: eventhub.outputs.eventHubName
    keyVaultUri: keyvault.outputs.keyVaultUri
    checkpointStorageAccountName: storage.outputs.storageAccountName
  }
}

module apim 'modules/apim.bicep' = {
  scope: rg
  name: 'apim'
  params: {
    env: env
    location: location
    namePrefix: namePrefix
    tags: tags
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsInstrumentationKey: monitoring.outputs.appInsightsInstrumentationKey
    modulaAdapterFqdn: containerApps.outputs.modulaAdapterFqdn
    d365AdapterFqdn: containerApps.outputs.d365AdapterFqdn
    datahubAdapterFqdn: containerApps.outputs.datahubAdapterFqdn
  }
}

module rbac 'modules/rbac.bicep' = {
  scope: rg
  name: 'rbac'
  params: {
    eventHubNamespaceName: eventhub.outputs.namespaceName
    keyVaultName: keyvault.outputs.keyVaultName
    storageAccountName: storage.outputs.storageAccountName
    modulaAdapterPrincipalId: containerApps.outputs.modulaAdapterPrincipalId
    d365AdapterPrincipalId: containerApps.outputs.d365AdapterPrincipalId
    datahubAdapterPrincipalId: containerApps.outputs.datahubAdapterPrincipalId
  }
}

output apimGatewayUrl string = apim.outputs.gatewayUrl
output eventHubNamespace string = eventhub.outputs.namespaceFqdn
