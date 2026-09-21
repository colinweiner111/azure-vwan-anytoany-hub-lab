param adminUsername string
@secure()
param adminPassword string
param vmSize string
param virtualNetworks array
param networkSecurityGroupIds array
param tags object

var cloudInit = base64('''#cloud-config
package_update: true
packages:
  - apache2
  - curl
  - hping3
  - iperf3
  - nmap
  - tcptraceroute
  - traceroute
runcmd:
  - [bash, -c, "echo $(hostname) > /var/www/html/index.html"]
''')

resource vmPublicIps 'Microsoft.Network/publicIPAddresses@2024-05-01' = [for virtualNetwork in virtualNetworks: {
  name: '${virtualNetwork.name}VM-pip'
  location: virtualNetwork.location
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

resource networkInterfaces 'Microsoft.Network/networkInterfaces@2024-05-01' = [for (virtualNetwork, index) in virtualNetworks: {
  name: '${virtualNetwork.name}VM-nic'
  location: virtualNetwork.location
  tags: tags
  properties: {
    networkSecurityGroup: {
      id: networkSecurityGroupIds[virtualNetwork.hubIndex]
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: vmPublicIps[index].id
          }
          subnet: {
            id: virtualNetwork.mainSubnetId
          }
        }
      }
    ]
  }
}]

resource virtualMachines 'Microsoft.Compute/virtualMachines@2024-07-01' = [for (virtualNetwork, index) in virtualNetworks: {
  name: '${virtualNetwork.name}VM'
  location: virtualNetwork.location
  zones: [
    '1'
  ]
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterfaces[index].id
          properties: {
            primary: true
          }
        }
      ]
    }
    osProfile: {
      computerName: '${virtualNetwork.name}VM'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: cloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: false
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
  }
}]

output virtualMachineNames array = [for virtualNetwork in virtualNetworks: '${virtualNetwork.name}VM']
output virtualMachinePublicIps array = [for index in range(0, length(virtualNetworks)): vmPublicIps[index].properties.ipAddress]
