param env string
param location string
param namePrefix string
param tags object

// Service Bus used only for dead-letter / operational queues (poison messages
// escalated out of adapter retry loops).
resource sb 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: 'sbns-${namePrefix}-${env}'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Standard' }
  properties: { minimumTlsVersion: '1.2' }
}

resource dlqD365 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: sb
  name: 'dlq-d365'
  properties: {
    maxDeliveryCount: 10
    defaultMessageTimeToLive: 'P14D'
    deadLetteringOnMessageExpiration: true
  }
}

resource dlqDatahub 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: sb
  name: 'dlq-datahub'
  properties: {
    maxDeliveryCount: 10
    defaultMessageTimeToLive: 'P14D'
    deadLetteringOnMessageExpiration: true
  }
}

output serviceBusName string = sb.name
