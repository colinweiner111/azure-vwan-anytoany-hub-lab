targetScope = 'subscription'

@description('Resource group name.')
param resourceGroupName string

@description('Azure region for Hub 1, Branch 1, and Spokes 1-3.')
param location1 string

@description('Azure region for Hub 2, Branch 2, and Spokes 4-6.')
param location2 string

@description('Virtual WAN name.')
param virtualWanName string = 'vwan-a2a'

@description('Linux administrator username.')
param adminUsername string = 'azureuser'

@description('Administrator password used by all lab VMs.')
@secure()
param adminPassword string

@description('CIDR allowed to SSH to the lab VMs.')
param sshSourceAddressPrefix string

@description('VM SKU used by all lab VMs.')
param vmSize string = 'Standard_D2ls_v7'

@description('Pre-shared key used by all site-to-site VPN connections.')
@secure()
param vpnSharedKey string

@description('Tags applied to resources.')
param tags object = {
  workload: 'azure-vwan-anytoany-hub-lab'
  environment: 'demo'
}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location1
  tags: tags
}

module network 'modules/network.bicep' = {
  scope: resourceGroup
  name: 'network-${uniqueString(deployment().name)}'
  params: {
    location1: location1
    location2: location2
    virtualWanName: virtualWanName
    sshSourceAddressPrefix: sshSourceAddressPrefix
    tags: tags
  }
}

module virtualMachines 'modules/virtual-machines.bicep' = {
  scope: resourceGroup
  name: 'virtual-machines-${uniqueString(deployment().name)}'
  params: {
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    virtualNetworks: network.outputs.virtualNetworks
    networkSecurityGroupIds: network.outputs.networkSecurityGroupIds
    tags: tags
  }
}

module vpnConnections 'modules/vpn-connections.bicep' = {
  scope: resourceGroup
  name: 'vpn-connections-${uniqueString(deployment().name)}'
  params: {
    location1: location1
    location2: location2
    virtualWanId: network.outputs.virtualWanId
    branchGatewayIds: network.outputs.branchGatewayIds
    branchGatewayPublicIps: network.outputs.branchGatewayPublicIps
    branchGatewayBgpIps: network.outputs.branchGatewayBgpIps
    branchAsns: network.outputs.branchAsns
    hubVpnGatewayPublicIps: network.outputs.hubVpnGatewayPublicIps
    hubVpnGatewayBgpIps: network.outputs.hubVpnGatewayBgpIps
    vpnSharedKey: vpnSharedKey
    tags: tags
  }
}

output resourceGroupName string = resourceGroup.name
output virtualWanId string = network.outputs.virtualWanId
output virtualHubIds array = network.outputs.virtualHubIds
output branchGatewayIds array = network.outputs.branchGatewayIds
output hubVpnGatewayIds array = network.outputs.hubVpnGatewayIds
output virtualMachineNames array = virtualMachines.outputs.virtualMachineNames
output hubVpnConnectionIds array = vpnConnections.outputs.hubVpnConnectionIds
output branchVpnConnectionIds array = vpnConnections.outputs.branchVpnConnectionIds
