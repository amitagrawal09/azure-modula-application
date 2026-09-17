param env string
param location string
param namePrefix string
param tags object

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${namePrefix}-${env}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: env == 'prod' ? 90 : 30
  }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${namePrefix}-${env}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

// Alert: Event Hub consumer lag surfaced via custom metric from adapters
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${namePrefix}-${env}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'modint'
    enabled: true
    emailReceivers: [
      {
        name: 'integration-oncall'
        emailAddress: 'integration-oncall@example.com'
        useCommonAlertSchema: true
      }
    ]
  }
}

output lawId string = law.id
output lawCustomerId string = law.properties.customerId
output lawSharedKey string = law.listKeys().primarySharedKey
output appInsightsId string = appi.id
output appInsightsConnectionString string = appi.properties.ConnectionString
output appInsightsInstrumentationKey string = appi.properties.InstrumentationKey
