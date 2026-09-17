param env string
param location string
param namePrefix string
param tags object
param eventHubNamespaceName string
param keyVaultName string
param storageAccountName string
param acrName string
param repoUrl string          // e.g. https://github.com/amitagrawal09/azure-modula-application.git
param repoBranch string = 'main'
param cdmSchemaRawUrl string  // raw URL of cdm/inventory-event-cdm.schema.json
param deploySimulator bool = true
param deployAdapters bool = false   // flip true once src/<adapter>/Dockerfile exists
@secure()
param d365ClientId string = ''
@secure()
param d365ClientSecret string = ''
@secure()
param d365BaseUrl string = ''
@secure()
param modulaApiKey string = ''

resource evhns 'Microsoft.EventHub/namespaces@2024-01-01' existing = { name: eventHubNamespaceName }
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = { name: keyVaultName }
resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: storageAccountName }
resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = { name: acrName }
resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' existing = { name: 'cae-${namePrefix}-${env}' }

// ---------- Identity that runs the post-deploy work ----------
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-postdeploy-${namePrefix}-${env}'
  location: location
  tags: tags
}

var roles = {
  schemaRegistryContributor: '5dffeca3-4936-4216-b2bc-10343a5abb25'
  acrPush: '8311e382-0749-4cb8-b61a-304f252e45ec'
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  kvSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
}

resource raSchema 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(evhns.id, uami.id, 'schema')
  scope: evhns
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.schemaRegistryContributor)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource raAcrPush 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, uami.id, 'push')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPush)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource raAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, uami.id, 'pull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPull)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Contributor on the RG so the script can update container apps when deployAdapters=true
resource raRg 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, uami.id, 'contrib')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.contributor)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- Key Vault secrets (only when values supplied) ----------
resource secD365Id 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(d365ClientId)) {
  parent: kv
  name: 'd365-client-id'
  properties: { value: d365ClientId }
}
resource secD365Secret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(d365ClientSecret)) {
  parent: kv
  name: 'd365-client-secret'
  properties: { value: d365ClientSecret }
}
resource secD365Url 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(d365BaseUrl)) {
  parent: kv
  name: 'd365-base-url'
  properties: { value: d365BaseUrl }
}
resource secD365Tenant 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(d365ClientId)) {
  parent: kv
  name: 'd365-tenant-id'
  properties: { value: tenant().tenantId }
}
resource secModula 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(modulaApiKey)) {
  parent: kv
  name: 'modula-api-key'
  properties: { value: modulaApiKey }
}

// ---------- Databricks Access Connector (Unity Catalog storage credential) ----------
resource dbxConnector 'Microsoft.Databricks/accessConnectors@2024-05-01' = {
  name: 'dbac-${namePrefix}-${env}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
}

resource raDbx 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sa.id, dbxConnector.id, 'blob')
  scope: sa
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalId: dbxConnector.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- Deployment script: schema registration + image builds + app updates ----------
resource script 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'ds-postdeploy-${namePrefix}-${env}'
  location: location
  tags: tags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uami.id}': {} }
  }
  dependsOn: [raSchema, raAcrPush, raAcrPull, raRg]
  properties: {
    azCliVersion: '2.63.0'
    retentionInterval: 'PT4H'
    timeout: 'PT45M'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      { name: 'EVHNS', value: eventHubNamespaceName }
      { name: 'ACR', value: acrName }
      { name: 'RG', value: resourceGroup().name }
      { name: 'ENVNAME', value: env }
      { name: 'REPO_URL', value: repoUrl }
      { name: 'REPO_BRANCH', value: repoBranch }
      { name: 'SCHEMA_URL', value: cdmSchemaRawUrl }
      { name: 'BUILD_SIM', value: string(deploySimulator) }
      { name: 'BUILD_ADAPTERS', value: string(deployAdapters) }
    ]
    scriptContent: '''
set -euo pipefail
echo "=== RBAC propagation grace period ==="
sleep 60

echo "=== 1. Register CDM schema in inventory-cdm ==="
curl -sSL "$SCHEMA_URL" -o /tmp/cdm.json
TOKEN=$(az account get-access-token --resource https://eventhubs.azure.net --query accessToken -o tsv)
for i in 1 2 3 4 5; do
  CODE=$(curl -s -o /tmp/resp.txt -w "%{http_code}" -X PUT \
    "https://$EVHNS.servicebus.windows.net/\$schemagroups/inventory-cdm/schemas/InventoryEventEnvelope?api-version=2020-09-01-preview" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json; serialization=Json" \
    --data-binary @/tmp/cdm.json) && [ "$CODE" -lt 300 ] && break
  echo "schema PUT attempt $i -> $CODE ($(cat /tmp/resp.txt | head -c 200)); retrying in 30s"; sleep 30
done
[ "$CODE" -lt 300 ] || { echo "schema registration failed"; exit 1; }
echo "schema registered (HTTP $CODE)"

SRC="$REPO_URL#$REPO_BRANCH"

if [ "$BUILD_SIM" = "true" ] || [ "$BUILD_SIM" = "True" ]; then
  echo "=== 2. Build simulator image from $SRC ==="
  for i in 1 2 3; do
    az acr build -r "$ACR" -t modula-simulator:latest "$SRC:src/modula-simulator" && break
    echo "acr build attempt $i failed (RBAC propagation?); retrying in 30s"; sleep 30
  done
fi

if [ "$BUILD_ADAPTERS" = "true" ] || [ "$BUILD_ADAPTERS" = "True" ]; then
  echo "=== 3. Build adapter images and roll container apps ==="
  for a in modula-adapter d365-adapter datahub-adapter; do
    az acr build -r "$ACR" -t "$a:latest" "$SRC:src/$a"
    az containerapp update -g "$RG" -n "ca-$a-$ENVNAME" \
      --image "$ACR.azurecr.io/$a:latest"
  done
  echo "NOTE: probes/targetPort 8080 + KEDA eventhub scaling applied by CI/CD workflow"
fi
echo "=== post-deploy complete ==="
'''
  }
}

// ---------- Simulator as a manual-trigger Container Apps job ----------
resource simJob 'Microsoft.App/jobs@2024-03-01' = if (deploySimulator) {
  name: 'caj-modula-sim-${env}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uami.id}': {} }
  }
  dependsOn: [script]
  properties: {
    environmentId: acaEnv.id
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 3900
      replicaRetryLimit: 0
      manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
      registries: [
        {
          server: acr.properties.loginServer
          identity: uami.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'simulator'
          image: '${acr.properties.loginServer}/modula-simulator:latest'
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'MODE', value: 'dry-run' }   // switch to api + creds when smoke-testing
            { name: 'RATE_PER_MIN', value: '30' }
            { name: 'DURATION_SEC', value: '120' }
          ]
        }
      ]
    }
  }
}

output postDeployIdentity string = uami.properties.principalId
output databricksConnectorId string = dbxConnector.id
output simulatorJobName string = deploySimulator ? 'caj-modula-sim-${env}' : ''
