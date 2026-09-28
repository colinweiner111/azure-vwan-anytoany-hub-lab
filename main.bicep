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
@minLength(12)
@maxLength(72)
param adminPassword string

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

var hub1Name = 'hub1'
var bastionVnetName = 'bastion-vnet'

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
    branchVpnEndpoints: network.outputs.branchVpnEndpoints
    branchAsns: network.outputs.branchAsns
    hubVpnGatewayPublicIps: network.outputs.hubVpnGatewayPublicIps
    hubVpnGatewayBgpIps: network.outputs.hubVpnGatewayBgpIps
    vpnSharedKey: vpnSharedKey
    tags: tags
  }
}

module bastion 'modules/bastion.bicep' = {
  scope: resourceGroup
  name: 'bastion-${uniqueString(deployment().name)}'
  params: {
    location: location1
    hubName: hub1Name
    bastionVnetName: bastionVnetName
    bastionSubnetPrefix: network.outputs.bastionSubnetPrefix
    tags: tags
  }
  dependsOn: [
    vpnConnections
  ]
}

output resourceGroupName string = resourceGroup.name
output virtualWanId string = network.outputs.virtualWanId
output virtualHubIds array = network.outputs.virtualHubIds
output bastionName string = bastion.outputs.bastionName
output branchGatewayIds array = network.outputs.branchGatewayIds
output hubVpnGatewayIds array = network.outputs.hubVpnGatewayIds
output virtualMachineNames array = virtualMachines.outputs.virtualMachineNames
output hubVpnConnectionIds array = vpnConnections.outputs.hubVpnConnectionIds
output branchVpnConnectionIds array = vpnConnections.outputs.branchVpnConnectionIds
