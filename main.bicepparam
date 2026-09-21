using './main.bicep'

param resourceGroupName = readEnvironmentVariable('AZURE_RESOURCE_GROUP_NAME', '')
param location1 = readEnvironmentVariable('AZURE_LOCATION1', '')
param location2 = readEnvironmentVariable('AZURE_LOCATION2', '')
param virtualWanName = 'vwan-a2a'
param adminUsername = 'azureuser'
param adminPassword = readEnvironmentVariable('AZURE_ADMIN_PASSWORD', '')
param sshSourceAddressPrefix = readEnvironmentVariable('AZURE_SSH_SOURCE_PREFIX', '')
param vmSize = 'Standard_D2ls_v7'
param vpnSharedKey = readEnvironmentVariable('AZURE_VPN_SHARED_KEY', '')
