param env string
param location string
param namePrefix string
param tags object
param infraSubnetId string
param logAnalyticsCustomerId string
@secure()
param logAnalyticsSharedKey string
param appInsightsConnectionString string
param eventHubNamespaceFqdn string
param eventHubName string
param keyVaultUri string
param checkpointStorageAccountName string

var isProd = env == 'prod'

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: 'acr${namePrefix}${env}'
  location: location
  tags: tags
  sku: { name: isProd ? 'Premium' : 'Basic' }
  properties: { adminUserEnabled: false }
}

resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${namePrefix}-${env}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: infraSubnetId
      internal: false
    }
    zoneRedundant: isProd
  }
}

var commonEnv = [
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
  { name: 'EVENTHUB_FQDN', value: eventHubNamespaceFqdn }
  { name: 'EVENTHUB_NAME', value: eventHubName }
  { name: 'KEYVAULT_URI', value: keyVaultUri }
  { name: 'CHECKPOINT_STORAGE_ACCOUNT', value: checkpointStorageAccountName }
  { name: 'CDM_SCHEMA_VERSION', value: '1.0.0' }
]

var adapters = [
  {
    name: 'modula-adapter'
    consumerGroup: ''
    minReplicas: 1
    maxReplicas: 10
    scaleRule: {
      name: 'http-scale'
      http: { metadata: { concurrentRequests: '50' } }
    }
  }
  {
    name: 'd365-adapter'
    consumerGroup: 'cg-d365'
    minReplicas: 1
    maxReplicas: 8
    scaleRule: {
      name: 'http-scale'
      http: { metadata: { concurrentRequests: '50' } }
    }
  }
  {
    name: 'datahub-adapter'
    consumerGroup: 'cg-datahub'
    minReplicas: 1
    maxReplicas: 8
    scaleRule: {
      name: 'http-scale'
      http: { metadata: { concurrentRequests: '50' } }
    }
  }
]

resource apps 'Microsoft.App/containerApps@2024-03-01' = [for a in adapters: {
  name: 'ca-${a.name}-${env}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 80
        transport: 'http'
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: 'system'
        }
      ]
    }
    template: {
      containers: [
        {
          name: a.name
          // Placeholder image at first deploy; CI/CD updates to ACR image
          image: 'mcr.microsoft.com/k8se/quickstart:latest'
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: concat(commonEnv, empty(a.consumerGroup) ? [] : [
            { name: 'EVENTHUB_CONSUMER_GROUP', value: a.consumerGroup }
          ])
        }
      ]
      scale: {
        minReplicas: a.minReplicas
        maxReplicas: a.maxReplicas
        rules: [a.scaleRule]
      }
    }
  }
}]

output modulaAdapterFqdn string = apps[0].properties.configuration.ingress.fqdn
output d365AdapterFqdn string = apps[1].properties.configuration.ingress.fqdn
output datahubAdapterFqdn string = apps[2].properties.configuration.ingress.fqdn
output modulaAdapterPrincipalId string = apps[0].identity.principalId
output d365AdapterPrincipalId string = apps[1].identity.principalId
output datahubAdapterPrincipalId string = apps[2].identity.principalId
output acrLoginServer string = acr.properties.loginServer
