param env string
param location string
param namePrefix string
param tags object

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-${namePrefix}-${env}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.40.0.0/22'] }
    subnets: [
      {
        name: 'snet-aca-infra'
        properties: {
          addressPrefix: '10.40.0.0/23'
          delegations: [
            {
              name: 'aca'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: '10.40.2.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource dnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zone in [
  'privatelink.servicebus.windows.net'
  'privatelink.vaultcore.azure.net'
  'privatelink.dfs.core.windows.net'
  'privatelink.blob.core.windows.net'
]: {
  name: zone
  location: 'global'
  tags: tags
}]

resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zone, i) in [
  'privatelink.servicebus.windows.net'
  'privatelink.vaultcore.azure.net'
  'privatelink.dfs.core.windows.net'
  'privatelink.blob.core.windows.net'
]: {
  name: 'link-${namePrefix}'
  parent: dnsZones[i]
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]

output vnetId string = vnet.id
output acaSubnetId string = vnet.properties.subnets[0].id
output peSubnetId string = vnet.properties.subnets[1].id
