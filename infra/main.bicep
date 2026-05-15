targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment used to generate resource names. Set via "azd env new".')
param environmentName string

@minLength(1)
@description('Primary Azure region for all resources.')
param location string

@description('Optional principal id (you) to grant Key Vault Secrets Officer for local management. Leave empty to skip.')
param principalId string = ''

@description('Name of the demo secret created in Key Vault.')
param secretName string = 'demo-secret'

@description('Initial value of the demo secret.')
@secure()
param secretInitialValue string = 'hello-from-akv-${uniqueString(newGuid())}'

@description('TTL (in seconds) the app uses to cache the secret in-memory before re-reading from Key Vault.')
param secretTtlSeconds int = 30

var abbrs = {
  keyVault: 'kv'
  managedIdentity: 'id'
  containerAppsEnv: 'cae'
  containerApp: 'ca'
  containerRegistry: 'cr'
  logAnalytics: 'log'
}

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: environmentName
  location: location
  tags: {
    'azd-env-name': environmentName
  }
}

module shared 'shared.bicep' = {
  name: 'shared-${resourceToken}'
  scope: rg
  params: {
    location: location
    environmentName: environmentName
    resourceToken: resourceToken
    abbrs: abbrs
    principalId: principalId
    secretName: secretName
    secretInitialValue: secretInitialValue
    secretTtlSeconds: secretTtlSeconds
  }
}

output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = shared.outputs.containerRegistryLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = shared.outputs.containerRegistryName
output AZURE_CONTAINER_APPS_ENVIRONMENT_NAME string = shared.outputs.containerAppsEnvironmentName
output AZURE_CONTAINER_APP_NAME string = shared.outputs.containerAppName
output AZURE_CONTAINER_APP_FQDN string = shared.outputs.containerAppFqdn
output KEY_VAULT_NAME string = shared.outputs.keyVaultName
output KEY_VAULT_URI string = shared.outputs.keyVaultUri
output SECRET_NAME string = secretName
output SECRET_TTL_SECONDS int = secretTtlSeconds
output AZURE_CLIENT_ID string = shared.outputs.managedIdentityClientId
