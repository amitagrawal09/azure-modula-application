param env string
param location string
param namePrefix string
param tags object
param appInsightsId string
@secure()
param appInsightsInstrumentationKey string
param modulaAdapterFqdn string
param d365AdapterFqdn string
param datahubAdapterFqdn string

resource apim 'Microsoft.ApiManagement/service@2023-09-01-preview' = {
  name: 'apim-${namePrefix}-${env}'
  location: location
  tags: tags
  sku: {
    name: env == 'prod' ? 'Standard' : 'Developer'
    capacity: 1
  }
  identity: { type: 'SystemAssigned' }
  properties: {
    publisherEmail: 'integration-team@example.com'
    publisherName: 'Integration Platform'
  }
}

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2023-09-01-preview' = {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: appInsightsId
    credentials: { instrumentationKey: appInsightsInstrumentationKey }
  }
}

var apis = [
  { name: 'modula-adapter',  path: 'modula-adapter/v1',  backend: modulaAdapterFqdn }
  { name: 'd365-adapter',    path: 'd365-adapter/v1',    backend: d365AdapterFqdn }
  { name: 'datahub-adapter', path: 'datahub-adapter/v1', backend: datahubAdapterFqdn }
]

resource apiDefs 'Microsoft.ApiManagement/service/apis@2023-09-01-preview' = [for a in apis: {
  parent: apim
  name: a.name
  properties: {
    displayName: a.name
    path: a.path
    protocols: ['https']
    serviceUrl: 'https://${a.backend}'
    subscriptionRequired: false
  }
}]

// Global policy: validate JWT (Entra ID), rate limit, correlation header
resource globalPolicy 'Microsoft.ApiManagement/service/policies@2023-09-01-preview' = {
  parent: apim
  name: 'policy'
  properties: {
    format: 'xml'
    value: '''
<policies>
  <inbound>
    <validate-jwt header-name="Authorization" failed-validation-httpcode="401">
      <openid-config url="https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration" />
      <audiences><audience>api://modula-integration</audience></audiences>
    </validate-jwt>
    <rate-limit-by-key calls="1000" renewal-period="60" counter-key="@(context.Request.IpAddress)" />
    <set-header name="x-correlation-id" exists-action="skip">
      <value>@(Guid.NewGuid().ToString())</value>
    </set-header>
  </inbound>
  <backend><forward-request /></backend>
  <outbound />
  <on-error />
</policies>
'''
  }
}

output gatewayUrl string = apim.properties.gatewayUrl
