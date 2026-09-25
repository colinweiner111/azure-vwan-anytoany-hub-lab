param location1 string
param location2 string
param virtualWanId string
param branchGatewayIds array
param branchVpnEndpoints array
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

// Each active-active branch instance is represented by its own VPN site.
resource vpnSites 'Microsoft.Network/vpnSites@2024-07-01' = [for endpoint in branchVpnEndpoints: {
  name: 'site-${branchDefinitions[endpoint.branchIndex].name}-instance${endpoint.instanceIndex + 1}'
  location: branchDefinitions[endpoint.branchIndex].location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [branchDefinitions[endpoint.branchIndex].addressPrefix]
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
            asn: branchAsns[endpoint.branchIndex]
            bgpPeeringAddress: endpoint.bgpIp
          }
          ipAddress: endpoint.publicIp
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

// Avoid overlapping connection writes against the same hub VPN gateway.
@batchSize(1)
resource hubVpnConnections 'Microsoft.Network/vpnGateways/vpnConnections@2024-07-01' = [for (endpoint, index) in branchVpnEndpoints: {
  parent: hubVpnGateways[endpoint.branchIndex]
  name: 'site-${branchDefinitions[endpoint.branchIndex].name}-instance${endpoint.instanceIndex + 1}-conn'
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
    connectionProtocol: 'IKEv2'
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

output hubVpnConnectionIds array = [for index in range(0, length(branchVpnEndpoints)): hubVpnConnections[index].id]
output branchVpnConnectionIds array = [for index in range(0, length(tunnelDefinitions)): branchConnections[index].id]
