param location string
param environmentName string
param resourceToken string
param abbrs object
param principalId string
param secretName string
@secure()
param secretInitialValue string
param secretTtlSeconds int

var tags = {
  'azd-env-name': environmentName
}

// User-assigned managed identity used by the Container App to read Key Vault and pull from ACR.
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${abbrs.managedIdentity}-${resourceToken}'
  location: location
  tags: tags
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${abbrs.logAnalytics}-${resourceToken}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: '${abbrs.containerRegistry}${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

// AcrPull on the registry to the UAMI so the Container App can pull images.
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, uami.id, 'acrpull')
  scope: acr
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2024-04-01-preview' = {
  name: '${abbrs.keyVault}-${resourceToken}'
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: null
    publicNetworkAccess: 'Enabled'
  }
}

// Key Vault Secrets User on the vault to the UAMI (read-only).
resource kvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, uami.id, 'kv-secrets-user')
  scope: keyVault
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}

// Optional: grant the deploying user Key Vault Secrets Officer so they can rotate the secret.
resource kvSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(keyVault.id, principalId, 'kv-secrets-officer')
  scope: keyVault
  properties: {
    principalId: principalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  }
}

// Seed the demo secret. The deployment principal (azd / pipeline SP) needs Secrets Officer to set this.
resource demoSecret 'Microsoft.KeyVault/vaults/secrets@2024-04-01-preview' = {
  parent: keyVault
  name: secretName
  properties: {
    value: secretInitialValue
  }
}

resource containerAppsEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${abbrs.containerAppsEnv}-${resourceToken}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${abbrs.containerApp}-${resourceToken}'
  location: location
  // azd uses this tag to identify which service in azure.yaml maps to this resource.
  tags: union(tags, {
    'azd-service-name': 'web'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  dependsOn: [
    acrPullRole
    kvSecretsUser
    demoSecret
  ]
  properties: {
    managedEnvironmentId: containerAppsEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
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
          name: 'web'
          // Bootstrapped with a placeholder; azd will build and push the real image and update the app.
          image: 'mcr.microsoft.com/k8se/quickstart:latest'
          resources: {
            cpu: json('0.5')
            memory: '1.0Gi'
          }
          env: [
            {
              name: 'KEY_VAULT_NAME'
              value: keyVault.name
            }
            {
              name: 'SECRET_NAME'
              value: secretName
            }
            {
              name: 'SECRET_TTL_SECONDS'
              value: string(secretTtlSeconds)
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: uami.properties.clientId
            }
            {
              name: 'PORT'
              value: '8080'
            }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/healthz'
                port: 8080
              }
              periodSeconds: 30
              timeoutSeconds: 5
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

output containerRegistryLoginServer string = acr.properties.loginServer
output containerRegistryName string = acr.name
output containerAppsEnvironmentName string = containerAppsEnv.name
output containerAppName string = containerApp.name
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output managedIdentityClientId string = uami.properties.clientId
output managedIdentityPrincipalId string = uami.properties.principalId
