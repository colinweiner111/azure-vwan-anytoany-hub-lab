param location1 string
param location2 string
param virtualWanName string
param sshSourceAddressPrefix string
param tags object

var hubDefinitions = [
  {
    name: 'hub1'
    addressPrefix: '192.168.1.0/24'
    location: location1
  }
  {
    name: 'hub2'
    addressPrefix: '192.168.2.0/24'
    location: location2
  }
]

var virtualNetworkDefinitions = [
  {
    name: 'branch1'
    addressPrefix: '10.100.0.0/16'
    mainSubnetPrefix: '10.100.0.0/24'
    gatewaySubnetPrefix: '10.100.100.0/26'
    hubIndex: 0
    isBranch: true
    location: location1
  }
  {
    name: 'branch2'
    addressPrefix: '10.200.0.0/16'
    mainSubnetPrefix: '10.200.0.0/24'
    gatewaySubnetPrefix: '10.200.100.0/26'
    hubIndex: 1
    isBranch: true
    location: location2
  }
  {
    name: 'spoke1'
    addressPrefix: '172.16.1.0/24'
    mainSubnetPrefix: '172.16.1.0/27'
    gatewaySubnetPrefix: ''
    hubIndex: 0
    isBranch: false
    location: location1
  }
  {
    name: 'spoke2'
    addressPrefix: '172.16.2.0/24'
    mainSubnetPrefix: '172.16.2.0/27'
    gatewaySubnetPrefix: ''
    hubIndex: 0
    isBranch: false
    location: location1
  }
  {
    name: 'spoke3'
    addressPrefix: '172.16.3.0/24'
    mainSubnetPrefix: '172.16.3.0/27'
    gatewaySubnetPrefix: ''
    hubIndex: 0
    isBranch: false
    location: location1
  }
  {
    name: 'spoke4'
    addressPrefix: '172.16.4.0/24'
    mainSubnetPrefix: '172.16.4.0/27'
    gatewaySubnetPrefix: ''
    hubIndex: 1
    isBranch: false
    location: location2
  }
  {
    name: 'spoke5'
    addressPrefix: '172.16.5.0/24'
    mainSubnetPrefix: '172.16.5.0/27'
    gatewaySubnetPrefix: ''
    hubIndex: 1
    isBranch: false
    location: location2
  }
  {
    name: 'spoke6'
    addressPrefix: '172.16.6.0/24'
    mainSubnetPrefix: '172.16.6.0/27'
    gatewaySubnetPrefix: ''
    hubIndex: 1
    isBranch: false
    location: location2
  }
]

var spokeDefinitions = filter(virtualNetworkDefinitions, item => !item.isBranch)
var branchDefinitions = filter(virtualNetworkDefinitions, item => item.isBranch)
var branchAsns = [
  65510
  65509
]

resource networkSecurityGroups 'Microsoft.Network/networkSecurityGroups@2024-05-01' = [for hub in hubDefinitions: {
  name: 'default-nsg-${hub.name}'
  location: hub.location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-ssh'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: 'Tcp'
          sourceAddressPrefix: sshSourceAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}]

resource virtualNetworks 'Microsoft.Network/virtualNetworks@2024-05-01' = [for definition in virtualNetworkDefinitions: {
  name: definition.name
  location: definition.location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [definition.addressPrefix]
    }
    subnets: concat([
      {
        name: 'main'
        properties: {
          addressPrefix: definition.mainSubnetPrefix
          networkSecurityGroup: {
            id: networkSecurityGroups[definition.hubIndex].id
          }
        }
      }
    ], definition.isBranch ? [
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: definition.gatewaySubnetPrefix
        }
      }
    ] : [])
  }
}]

resource virtualWan 'Microsoft.Network/virtualWans@2024-07-01' = {
  name: virtualWanName
  location: location1
  tags: tags
  properties: {
    allowBranchToBranchTraffic: true
    type: 'Standard'
  }
}

resource virtualHubs 'Microsoft.Network/virtualHubs@2024-05-01' = [for hub in hubDefinitions: {
  name: hub.name
  location: hub.location
  tags: tags
  properties: {
    addressPrefix: hub.addressPrefix
    sku: 'Standard'
    virtualWan: {
      id: virtualWan.id
    }
  }
}]

resource spokeConnections 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2024-05-01' = [for (spoke, index) in spokeDefinitions: {
  parent: virtualHubs[spoke.hubIndex]
  name: '${spoke.name}conn'
  properties: {
    enableInternetSecurity: false
    remoteVirtualNetwork: {
      id: virtualNetworks[index + 2].id
    }
  }
}]

resource branchGatewayPublicIps 'Microsoft.Network/publicIPAddresses@2024-05-01' = [for branch in branchDefinitions: {
  name: '${branch.name}-vpngw-pip'
  location: branch.location
  zones: [
    '1'
    '2'
    '3'
  ]
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}]

resource branchGateways 'Microsoft.Network/virtualNetworkGateways@2024-05-01' = [for (branch, index) in branchDefinitions: {
  name: '${branch.name}-vpngw'
  location: branch.location
  tags: tags
  properties: {
    activeActive: false
    enableBgp: true
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    vpnGatewayGeneration: 'Generation1'
    sku: {
      name: 'VpnGw1AZ'
      tier: 'VpnGw1AZ'
    }
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: branchGatewayPublicIps[index].id
          }
          subnet: {
            id: '${virtualNetworks[index].id}/subnets/GatewaySubnet'
          }
        }
      }
    ]
    bgpSettings: {
      asn: branchAsns[index]
      peerWeight: 0
    }
  }
}]

resource hubVpnGateways 'Microsoft.Network/vpnGateways@2024-07-01' = [for (hub, index) in hubDefinitions: {
  name: '${hub.name}-vpngw'
  location: hub.location
  tags: tags
  properties: {
    virtualHub: {
      id: virtualHubs[index].id
    }
    vpnGatewayScaleUnit: 1
    bgpSettings: {
      asn: 65515
      peerWeight: 0
    }
  }
}]

output virtualWanId string = virtualWan.id
output virtualHubIds array = [for index in range(0, length(hubDefinitions)): virtualHubs[index].id]
output virtualNetworks array = [for (definition, index) in virtualNetworkDefinitions: {
  name: definition.name
  id: virtualNetworks[index].id
  mainSubnetId: '${virtualNetworks[index].id}/subnets/main'
  hubIndex: definition.hubIndex
  location: definition.location
}]
output networkSecurityGroupIds array = [for index in range(0, length(hubDefinitions)): networkSecurityGroups[index].id]
output branchGatewayIds array = [for index in range(0, length(branchDefinitions)): branchGateways[index].id]
output branchGatewayPublicIps array = [for index in range(0, length(branchDefinitions)): branchGatewayPublicIps[index].properties.ipAddress]
output branchGatewayBgpIps array = [for index in range(0, length(branchDefinitions)): branchGateways[index].properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]]
output branchAsns array = branchAsns
output hubVpnGatewayIds array = [for index in range(0, length(hubDefinitions)): hubVpnGateways[index].id]
output hubVpnGatewayPublicIps array = [
  hubVpnGateways[0].properties.bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]
  hubVpnGateways[0].properties.bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]
  hubVpnGateways[1].properties.bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]
  hubVpnGateways[1].properties.bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]
]
output hubVpnGatewayBgpIps array = [
  hubVpnGateways[0].properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
  hubVpnGateways[0].properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]
  hubVpnGateways[1].properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
  hubVpnGateways[1].properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]
]
