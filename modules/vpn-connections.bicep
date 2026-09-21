param location1 string
param location2 string
param virtualWanId string
param branchGatewayIds array
param branchGatewayPublicIps array
param branchGatewayBgpIps array
param branchAsns array
param hubVpnGatewayPublicIps array
param hubVpnGatewayBgpIps array
@secure()
param vpnSharedKey string
param tags object

var branchDefinitions = [
  {
    name: 'branch1'
    addressPrefix: '10.100.0.0/16'
    location: location1
  }
  {
    name: 'branch2'
    addressPrefix: '10.200.0.0/16'
    location: location2
  }
]

var hubVpnGatewayNames = [
  'hub1-vpngw'
  'hub2-vpngw'
]

var tunnelDefinitions = [
  {
    name: 'branch1-to-hub1-gw1'
    localGatewayName: 'lng-hub1-gw1'
    branchIndex: 0
    endpointIndex: 0
  }
  {
    name: 'branch1-to-hub1-gw2'
    localGatewayName: 'lng-hub1-gw2'
    branchIndex: 0
    endpointIndex: 1
  }
  {
    name: 'branch2-to-hub2-gw1'
    localGatewayName: 'lng-hub2-gw1'
    branchIndex: 1
    endpointIndex: 2
  }
  {
    name: 'branch2-to-hub2-gw2'
    localGatewayName: 'lng-hub2-gw2'
    branchIndex: 1
    endpointIndex: 3
  }
]

resource vpnSites 'Microsoft.Network/vpnSites@2024-07-01' = [for (branch, index) in branchDefinitions: {
  name: 'site-${branch.name}'
  location: branch.location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [branch.addressPrefix]
    }
    deviceProperties: {
      deviceModel: 'Azure VPN Gateway'
      deviceVendor: 'Microsoft'
      linkSpeedInMbps: 50
    }
    virtualWan: {
      id: virtualWanId
    }
    vpnSiteLinks: [
      {
        name: 'link1'
        properties: {
          bgpProperties: {
            asn: branchAsns[index]
            bgpPeeringAddress: branchGatewayBgpIps[index]
          }
          ipAddress: branchGatewayPublicIps[index]
          linkProperties: {
            linkProviderName: 'Azure'
            linkSpeedInMbps: 50
          }
        }
      }
    ]
  }
}]

resource hubVpnGateways 'Microsoft.Network/vpnGateways@2024-07-01' existing = [for gatewayName in hubVpnGatewayNames: {
  name: gatewayName
}]

resource hubVpnConnections 'Microsoft.Network/vpnGateways/vpnConnections@2024-07-01' = [for (branch, index) in branchDefinitions: {
  parent: hubVpnGateways[index]
  name: 'site-${branch.name}-conn'
  properties: {
    enableInternetSecurity: true
    remoteVpnSite: {
      id: vpnSites[index].id
    }
    vpnLinkConnections: [
      {
        name: 'link1'
        properties: {
          connectionBandwidth: 50
          enableBgp: true
          sharedKey: vpnSharedKey
          vpnConnectionProtocolType: 'IKEv2'
          vpnSiteLink: {
            id: '${vpnSites[index].id}/vpnSiteLinks/link1'
          }
        }
      }
    ]
  }
}]

resource localNetworkGateways 'Microsoft.Network/localNetworkGateways@2024-05-01' = [for tunnel in tunnelDefinitions: {
  name: tunnel.localGatewayName
  location: branchDefinitions[tunnel.branchIndex].location
  tags: tags
  properties: {
    gatewayIpAddress: hubVpnGatewayPublicIps[tunnel.endpointIndex]
    localNetworkAddressSpace: {
      addressPrefixes: []
    }
    bgpSettings: {
      asn: 65515
      bgpPeeringAddress: hubVpnGatewayBgpIps[tunnel.endpointIndex]
      peerWeight: 0
    }
  }
}]

resource branchConnections 'Microsoft.Network/connections@2024-05-01' = [for (tunnel, index) in tunnelDefinitions: {
  name: tunnel.name
  location: branchDefinitions[tunnel.branchIndex].location
  tags: tags
  properties: {
    connectionType: 'IPsec'
    enableBgp: true
    sharedKey: vpnSharedKey
    #disable-next-line BCP035
    virtualNetworkGateway1: {
      id: branchGatewayIds[tunnel.branchIndex]
    }
    #disable-next-line BCP035
    localNetworkGateway2: {
      id: localNetworkGateways[index].id
    }
  }
}]

output hubVpnConnectionIds array = [for index in range(0, length(branchDefinitions)): hubVpnConnections[index].id]
output branchVpnConnectionIds array = [for index in range(0, length(tunnelDefinitions)): branchConnections[index].id]
