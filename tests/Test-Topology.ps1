#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) "vwan-topology-$([guid]::NewGuid())"
$compiledFile = Join-Path $scratch 'main.json'
$parameterFile = Join-Path $scratch 'parameters.json'
$endpointFixture = Join-Path $scratch 'endpoints.bicepparam'
$endpointResult = Join-Path $scratch 'endpoints.json'
$envNames = @(
    'AZURE_RESOURCE_GROUP_NAME', 'AZURE_LOCATION1', 'AZURE_LOCATION2',
    'AZURE_ADMIN_PASSWORD', 'AZURE_VPN_SHARED_KEY'
)
$savedEnvironment = @{}
$checks = 0

function Assert-Equal {
    param($Actual, $Expected, [string] $Message)
    if ($Actual -cne $Expected) { throw "FAIL: $Message" }
    $script:checks++
}

function Assert-Contains {
    param([string] $Actual, [string] $Expected, [string] $Message)
    Assert-Equal $Actual.Contains($Expected) $true $Message
}

function Get-Resource {
    param($Template, [string] $Type)
    $foundResources = @($Template.resources | Where-Object type -eq $Type)
    Assert-Equal $foundResources.Count 1 "Exactly one resource declaration of type $Type"
    return $foundResources[0]
}

try {
    [void](New-Item -ItemType Directory -Path $scratch)
    foreach ($name in $envNames) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    az bicep build --file (Join-Path $repository 'main.bicep') --outfile $compiledFile
    if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed.' }
    $template = Get-Content -Raw $compiledFile | ConvertFrom-Json -Depth 100
    $modules = @($template.resources | Where-Object type -eq 'Microsoft.Resources/deployments')
    Assert-Equal $modules.Count 4 'Four nested modules'
    $network = ($modules | Where-Object name -Like "*'network-*").properties.template
    $vms = ($modules | Where-Object name -Like "*'virtual-machines-*").properties.template
    $vpnModule = $modules | Where-Object name -Like "*'vpn-connections-*"
    $vpn = $vpnModule.properties.template
    $bastionModule = $modules | Where-Object name -Like "*'bastion-*"
    $bastion = $bastionModule.properties.template

    Assert-Equal $template.parameters.adminPassword.type 'securestring' 'VM password remains secure'
    Assert-Equal $template.parameters.adminPassword.minLength 12 'ARM password minimum'
    Assert-Equal $template.parameters.adminPassword.maxLength 72 'ARM password maximum'
    Assert-Equal $template.parameters.vpnSharedKey.type 'securestring' 'PSK remains secure'
    Assert-Equal $template.parameters.vmSize.defaultValue 'Standard_D2ls_v7' 'VM SKU unchanged'
    Assert-Equal $network.variables.hubDefinitions.Count 2 'Two hubs'
    Assert-Equal ($network.variables.hubDefinitions.addressPrefix -join ',') '192.168.1.0/24,192.168.2.0/24' 'Hub prefixes unchanged'
    Assert-Equal $network.variables.virtualNetworkDefinitions.Count 8 'Eight VNets'
    $branches = @($network.variables.virtualNetworkDefinitions | Where-Object isBranch)
    $spokes = @($network.variables.virtualNetworkDefinitions | Where-Object { -not $_.isBranch })
    Assert-Equal $branches.Count 2 'Two branches'
    Assert-Equal $spokes.Count 6 'Six spokes'
    Assert-Equal ($branches.addressPrefix -join ',') '10.100.0.0/16,10.200.0.0/16' 'Branch prefixes unchanged'
    Assert-Equal ($network.variables.branchAsns -join ',') '65510,65509' 'Branch ASNs unchanged'
    foreach ($index in 0..5) {
        Assert-Equal $spokes[$index].addressPrefix "172.16.$($index + 1).0/24" "Spoke $index prefix"
        Assert-Equal $spokes[$index].hubIndex ([int][math]::Floor($index / 3)) "Spoke $index local hub"
    }
    Assert-Equal $network.variables.bastionVnetName 'bastion-vnet' 'Bastion VNet name'
    Assert-Equal $network.variables.bastionVnetPrefix '10.250.0.0/24' 'Bastion VNet prefix'
    Assert-Equal $network.variables.bastionSubnetPrefix '10.250.0.0/26' 'Bastion subnet prefix'
    $bastionVnet = @($network.resources | Where-Object {
        $_.type -eq 'Microsoft.Network/virtualNetworks' -and $_.name -eq "[variables('bastionVnetName')]"
    })
    Assert-Equal $bastionVnet.Count 1 'Dedicated Bastion VNet'
    Assert-Equal $bastionVnet[0].location "[parameters('location1')]" 'Bastion deploys in Region 1'
    Assert-Equal $bastionVnet[0].properties.addressSpace.addressPrefixes[0] "[variables('bastionVnetPrefix')]" 'Bastion VNet uses management prefix'
    $workloadNsg = Get-Resource $network 'Microsoft.Network/networkSecurityGroups'
    Assert-Equal $workloadNsg.properties.securityRules.Count 1 'Only one workload inbound allow rule'
    $bastionSshRule = @($workloadNsg.properties.securityRules | Where-Object name -eq 'allow-bastion-ssh')
    Assert-Equal $bastionSshRule.Count 1 'Workload NSGs allow Bastion SSH'
    Assert-Equal $bastionSshRule[0].properties.sourceAddressPrefix "[variables('bastionSubnetPrefix')]" 'Bastion SSH source is scoped to its subnet'
    Assert-Equal $bastionSshRule[0].properties.destinationPortRange '22' 'Bastion reaches SSH only'
    Assert-Equal @($workloadNsg.properties.securityRules | Where-Object {
        $_.properties.destinationPortRange -eq '22' -and
        $_.properties.sourceAddressPrefix -ne "[variables('bastionSubnetPrefix')]"
    }).Count 0 'No direct Internet SSH allow rule'

    Assert-Equal $template.variables.hub1Name 'hub1' 'Main template defines the Bastion hub deterministically'
    Assert-Equal $template.variables.bastionVnetName 'bastion-vnet' 'Main template defines the Bastion VNet deterministically'
    Assert-Equal $bastionModule.properties.parameters.hubName.value "[variables('hub1Name')]" 'Bastion connects to Hub 1 without a runtime module output'
    Assert-Equal $bastionModule.properties.parameters.bastionVnetName.value "[variables('bastionVnetName')]" 'Bastion uses the management VNet without a runtime module output'
    $vpnDependencies = @($bastionModule.dependsOn | Where-Object { $_.Contains("'vpn-connections-") })
    Assert-Equal $vpnDependencies.Count 1 'Bastion deploys after VPN connections'
    $bastionHost = Get-Resource $bastion 'Microsoft.Network/bastionHosts'
    Assert-Equal $bastionHost.sku.name 'Standard' 'Bastion Standard SKU'
    Assert-Equal $bastionHost.properties.enableIpConnect $true 'Bastion IP-based connections enabled'
    Assert-Equal $bastionHost.properties.enableTunneling $true 'Bastion native-client tunneling enabled'
    $bastionSubnet = Get-Resource $bastion 'Microsoft.Network/virtualNetworks/subnets'
    Assert-Contains $bastionSubnet.name 'AzureBastionSubnet' 'Required Bastion subnet name'
    Assert-Equal $bastionSubnet.properties.addressPrefix "[parameters('bastionSubnetPrefix')]" 'Bastion subnet prefix is wired from network module'
    Assert-Contains $bastionSubnet.properties.networkSecurityGroup.id "'bastion-nsg'" 'Bastion subnet uses dedicated NSG'
    $bastionNsg = Get-Resource $bastion 'Microsoft.Network/networkSecurityGroups'
    Assert-Equal $bastionNsg.properties.securityRules.Count 8 'All required Bastion NSG rules'
    $actualBastionRules = @($bastionNsg.properties.securityRules.name | Sort-Object) -join ','
    $expectedBastionRules = @(
        'AllowAzureCloudOutbound', 'AllowAzureLoadBalancerInbound', 'AllowBastionCommunication',
        'AllowBastionHostCommunication', 'AllowGatewayManagerInbound', 'AllowHttpOutbound',
        'AllowHttpsInbound', 'AllowSshRdpOutbound'
    ) | Sort-Object
    Assert-Equal $actualBastionRules ($expectedBastionRules -join ',') 'Required Bastion NSG rule names'
    $bastionConnection = Get-Resource $bastion 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections'
    Assert-Equal $bastionConnection.properties.enableInternetSecurity $false 'Bastion connection does not enable internet security'
    Assert-Equal ($null -eq $bastionConnection.properties.routingConfiguration) $true 'Bastion uses default Virtual WAN routing'
    Assert-Contains $bastionConnection.properties.remoteVirtualNetwork.id "parameters('bastionVnetName')" 'Bastion connection targets management VNet'

    $endpointDefinition = $network.variables.copy | Where-Object name -eq 'branchEndpointDefinitions'
    Assert-Equal $endpointDefinition.count "[length(range(0, mul(length(variables('branchDefinitions')), 2)))]" 'Two endpoints per branch'
    Assert-Equal $endpointDefinition.input.branchIndex "[div(range(0, mul(length(variables('branchDefinitions')), 2))[copyIndex('branchEndpointDefinitions')], 2)]" 'Endpoints grouped by branch'
    Assert-Equal $endpointDefinition.input.instanceIndex "[mod(range(0, mul(length(variables('branchDefinitions')), 2))[copyIndex('branchEndpointDefinitions')], 2)]" 'Both branch instances represented'
    Assert-Equal $endpointDefinition.input.ipConfigurationName "[if(equals(mod(range(0, mul(length(variables('branchDefinitions')), 2))[copyIndex('branchEndpointDefinitions')], 2), 0), 'default', 'secondary')]" 'Distinct instance configuration names'

    $gateway = Get-Resource $network 'Microsoft.Network/virtualNetworkGateways'
    Assert-Equal $gateway.properties.activeActive $true 'Branch gateways active-active'
    Assert-Equal $gateway.properties.enableBgp $true 'Branch BGP enabled'
    Assert-Equal $gateway.properties.sku.name 'VpnGw1AZ' 'Branch SKU unchanged'
    Assert-Equal $gateway.properties.vpnGatewayGeneration 'Generation1' 'Branch generation unchanged'
    $ipConfigurations = $gateway.properties.copy | Where-Object name -eq 'ipConfigurations'
    Assert-Equal $ipConfigurations.count '[length(range(0, 2))]' 'Two gateway IP configurations'
    $instanceIndex = "add(mul(copyIndex(), 2), range(0, 2)[copyIndex('ipConfigurations')])"
    Assert-Equal $ipConfigurations.input.name "[variables('branchEndpointDefinitions')[$instanceIndex].ipConfigurationName]" 'Gateway configuration matches endpoint identity'
    Assert-Contains $ipConfigurations.input.properties.publicIPAddress.id "variables('branchEndpointDefinitions')[$instanceIndex]" 'Each gateway instance selects its own public IP'
    Assert-Contains $ipConfigurations.input.properties.subnet.id '/subnets/GatewaySubnet' 'Both instances use GatewaySubnet'
    $publicIp = Get-Resource $network 'Microsoft.Network/publicIPAddresses'
    Assert-Equal $publicIp.copy.count "[length(variables('branchEndpointDefinitions'))]" 'Four branch public IPs'
    Assert-Equal $publicIp.sku.name 'Standard' 'Branch public IP SKU'
    Assert-Equal ($publicIp.zones -join ',') '1,2,3' 'Branch public IP zones'
    Assert-Equal $publicIp.properties.publicIPAllocationMethod 'Static' 'Static branch public IPs'
    Assert-Contains $publicIp.name "equals(variables('branchEndpointDefinitions')[copyIndex()].instanceIndex, 0)" 'Unique primary and secondary public IP names'
    Assert-Contains $publicIp.name "'{0}-vpngw-pip2'" 'Secondary public IP name'

    $endpoints = $network.outputs.branchVpnEndpoints.copy
    Assert-Equal $endpoints.count "[length(variables('branchEndpointDefinitions'))]" 'Every endpoint exported'
    Assert-Equal $endpoints.input.branchIndex "[variables('branchEndpointDefinitions')[copyIndex()].branchIndex]" 'Export preserves branch identity'
    Assert-Equal $endpoints.input.instanceIndex "[variables('branchEndpointDefinitions')[copyIndex()].instanceIndex]" 'Export preserves instance identity'
    Assert-Contains $endpoints.input.publicIp "variables('branchEndpointDefinitions')[copyIndex()]" 'Export references matching public IP'
    Assert-Contains $endpoints.input.bgpIp "variables('branchDefinitions')[variables('branchEndpointDefinitions')[copyIndex()].branchIndex]" 'BGP peer comes from correct branch gateway'
    Assert-Contains $endpoints.input.bgpIp "filter(reference(" 'BGP lookup filters returned peers'
    Assert-Contains $endpoints.input.bgpIp "endsWith(toLower(lambdaVariables('peer').ipconfigurationId), format('/ipconfigurations/{0}', variables('branchEndpointDefinitions')[copyIndex()].ipConfigurationName))" 'BGP lookup matches configuration identity, independent of response order'
    Assert-Contains $endpoints.input.bgpIp '[0].defaultBgpIpAddresses[0]' 'Selected peer provides default BGP address'
    Assert-Contains $vpnModule.properties.parameters.branchVpnEndpoints.value '.outputs.branchVpnEndpoints.value' 'Endpoint objects wired to VPN module'

    $site = Get-Resource $vpn 'Microsoft.Network/vpnSites'
    Assert-Equal $site.copy.count "[length(parameters('branchVpnEndpoints'))]" 'Four sites, one per instance'
    Assert-Contains $site.name "add(parameters('branchVpnEndpoints')[copyIndex()].instanceIndex, 1)" 'Unique site name per instance'
    Assert-Contains $site.location "parameters('branchVpnEndpoints')[copyIndex()].branchIndex" 'Site uses branch region'
    Assert-Equal $site.properties.vpnSiteLinks.Count 1 'One link per instance site'
    $link = $site.properties.vpnSiteLinks[0].properties
    Assert-Equal $link.bgpProperties.asn "[parameters('branchAsns')[parameters('branchVpnEndpoints')[copyIndex()].branchIndex]]" 'Site uses branch ASN'
    Assert-Equal $link.bgpProperties.bgpPeeringAddress "[parameters('branchVpnEndpoints')[copyIndex()].bgpIp]" 'Site uses matching BGP address'
    Assert-Equal $link.ipAddress "[parameters('branchVpnEndpoints')[copyIndex()].publicIp]" 'Site uses matching public IP'
    $hubConnection = Get-Resource $vpn 'Microsoft.Network/vpnGateways/vpnConnections'
    Assert-Equal $hubConnection.copy.count "[length(parameters('branchVpnEndpoints'))]" 'Four hub-side site connections'
    Assert-Equal $hubConnection.copy.mode 'serial' 'Hub connection writes are serialized'
    Assert-Equal $hubConnection.copy.batchSize 1 'Only one hub connection is provisioned at a time'
    Assert-Contains $hubConnection.name "variables('hubVpnGatewayNames')[parameters('branchVpnEndpoints')[copyIndex()].branchIndex]" 'Each instance connects only to local hub'
    Assert-Equal $hubConnection.properties.vpnLinkConnections.Count 1 'One link connection per site'
    $hubLink = $hubConnection.properties.vpnLinkConnections[0].properties
    Assert-Equal $hubLink.enableBgp $true 'Hub connection BGP'
    Assert-Equal $hubLink.vpnConnectionProtocolType 'IKEv2' 'Hub connection IKEv2'
    Assert-Equal $hubLink.sharedKey "[parameters('vpnSharedKey')]" 'Hub link PSK'
    $siteId = $hubConnection.properties.remoteVpnSite.id.Trim('[', ']')
    Assert-Contains $hubLink.vpnSiteLink.id $siteId 'Link connection references same site as parent'
    Assert-Equal $vpn.outputs.hubVpnConnectionIds.copy.count "[length(range(0, length(parameters('branchVpnEndpoints'))))]" 'All four hub connections exported'

    Assert-Equal $vpn.variables.tunnelDefinitions.Count 4 'Four branch-side connection resources retained'
    foreach ($index in 0..3) {
        $tunnel = $vpn.variables.tunnelDefinitions[$index]
        Assert-Equal $tunnel.branchIndex ([int][math]::Floor($index / 2)) "Branch connection $index stays local"
        Assert-Equal $tunnel.endpointIndex $index "Branch connection $index targets distinct hub endpoint"
    }
    $branchConnection = Get-Resource $vpn 'Microsoft.Network/connections'
    Assert-Equal $branchConnection.properties.enableBgp $true 'Branch connection BGP'
    Assert-Equal $branchConnection.properties.connectionType 'IPsec' 'Branch connection IPsec'
    Assert-Equal $branchConnection.properties.connectionProtocol 'IKEv2' 'Branch connection IKEv2 matches hub'
    Assert-Equal $branchConnection.properties.sharedKey $hubLink.sharedKey 'PSK consistent in both directions'
    $localGateway = Get-Resource $vpn 'Microsoft.Network/localNetworkGateways'
    Assert-Equal $localGateway.properties.bgpSettings.asn 65515 'Local gateways use hub ASN'
    Assert-Equal $localGateway.properties.gatewayIpAddress "[parameters('hubVpnGatewayPublicIps')[variables('tunnelDefinitions')[copyIndex()].endpointIndex]]" 'Local gateway selects correct hub public endpoint'
    Assert-Equal $localGateway.properties.bgpSettings.bgpPeeringAddress "[parameters('hubVpnGatewayBgpIps')[variables('tunnelDefinitions')[copyIndex()].endpointIndex]]" 'Local gateway selects matching hub BGP endpoint'

    $wan = Get-Resource $network 'Microsoft.Network/virtualWans'
    Assert-Equal $wan.properties.type 'Standard' 'Standard WAN preserved'
    Assert-Equal $wan.properties.allowBranchToBranchTraffic $true 'Branch transit preserved'
    $spokeConnection = Get-Resource $network 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections'
    Assert-Equal ($null -eq $spokeConnection.properties.routingConfiguration) $true 'Spoke routing defaults preserved'
    Assert-Equal ($null -eq $hubConnection.properties.routingConfiguration) $true 'VPN routing defaults preserved'
    $vm = Get-Resource $vms 'Microsoft.Compute/virtualMachines'
    Assert-Equal $vm.copy.count "[length(parameters('virtualNetworks'))]" 'One VM per VNet preserved'
    Assert-Equal $vm.properties.osProfile.linuxConfiguration.disablePasswordAuthentication $false 'VM password auth preserved'

    # Evaluate the production endpoint expressions with shuffled, mixed-case service responses.
    $source = Get-Content -Raw (Join-Path $repository 'modules\network.bicep')
    $definitions = [regex]::Match($source, '(?ms)^var branchEndpointDefinitions = \[for .*?^\}\]').Value
    $output = [regex]::Match($source, '(?ms)^output branchVpnEndpoints array = \[for .*?^\}\]').Value
    Assert-Equal ([string]::IsNullOrEmpty($definitions)) $false 'Endpoint definitions found for fixture evaluation'
    Assert-Equal ([string]::IsNullOrEmpty($output)) $false 'Endpoint output found for fixture evaluation'
    $fixture = @'
using none
var branchDefinitions = [{ name: 'branch1' }, { name: 'branch2' }]
var branchGatewayPublicIps = [
  { properties: { ipAddress: '203.0.113.1' } }
  { properties: { ipAddress: '203.0.113.2' } }
  { properties: { ipAddress: '203.0.113.3' } }
  { properties: { ipAddress: '203.0.113.4' } }
]
var branchGateways = [
  {
    properties: {
      bgpSettings: {
        bgpPeeringAddresses: [
          {
            ipconfigurationId: '/gateways/branch1/ipConfigurations/SECONDARY'
            defaultBgpIpAddresses: ['10.100.100.5']
          }
          {
            ipconfigurationId: '/gateways/branch1/ipConfigurations/DEFAULT'
            defaultBgpIpAddresses: ['10.100.100.4']
          }
        ]
      }
    }
  }
  {
    properties: {
      bgpSettings: {
        bgpPeeringAddresses: [
          {
            ipconfigurationId: '/gateways/branch2/IPCONFIGURATIONS/default'
            defaultBgpIpAddresses: ['10.200.100.4']
          }
          {
            ipconfigurationId: '/gateways/branch2/IPCONFIGURATIONS/secondary'
            defaultBgpIpAddresses: ['10.200.100.5']
          }
        ]
      }
    }
  }
]
'@
    $fixture += "`n$definitions`n" + $output.Replace('output branchVpnEndpoints array', 'var branchVpnEndpoints') + "`nparam endpoints = branchVpnEndpoints`n"
    [IO.File]::WriteAllText($endpointFixture, $fixture)
    az bicep build-params --file $endpointFixture --outfile $endpointResult
    if ($LASTEXITCODE -ne 0) { throw 'Offline BGP endpoint evaluation failed.' }
    $evaluatedEndpoints = (Get-Content -Raw $endpointResult | ConvertFrom-Json -Depth 20).parameters.endpoints.value
    Assert-Equal $evaluatedEndpoints.Count 4 'Four evaluated endpoint objects'
    $expectedBgpIps = @('10.100.100.4', '10.100.100.5', '10.200.100.4', '10.200.100.5')
    foreach ($index in 0..3) {
        $endpoint = $evaluatedEndpoints[$index]
        Assert-Equal $endpoint.branchIndex ([int][math]::Floor($index / 2)) "Evaluated endpoint $index branch"
        Assert-Equal $endpoint.instanceIndex ($index % 2) "Evaluated endpoint $index instance"
        Assert-Equal $endpoint.publicIp "203.0.113.$($index + 1)" "Evaluated endpoint $index public IP"
        Assert-Equal $endpoint.bgpIp $expectedBgpIps[$index] "Evaluated endpoint $index BGP pairing despite response order"
    }

    $dummyValues = @('local-test-only', 'westus3', 'eastus2', 'Local-Test-Only-123!', 'Local-Test-PSK!')
    foreach ($index in 0..($envNames.Count - 1)) {
        [Environment]::SetEnvironmentVariable($envNames[$index], $dummyValues[$index])
    }
    az bicep build-params --file (Join-Path $repository 'main.bicepparam') --outfile $parameterFile
    if ($LASTEXITCODE -ne 0) { throw 'Bicep parameter compilation failed.' }
    $parameters = (Get-Content -Raw $parameterFile | ConvertFrom-Json).parameters
    $parameterNames = @('resourceGroupName', 'location1', 'location2', 'adminPassword', 'vpnSharedKey')
    foreach ($index in 0..($parameterNames.Count - 1)) {
        Assert-Equal $parameters.($parameterNames[$index]).value $dummyValues[$index] "Environment binding $($parameterNames[$index])"
    }
    Write-Output "PASS: $checks compiled-template and parameter assertions. No Azure deployment or connectivity tests were run."
}
finally {
    foreach ($name in $savedEnvironment.Keys) {
        if ($null -eq $savedEnvironment[$name]) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
        }
    }
    foreach ($file in $compiledFile, $parameterFile, $endpointFixture, $endpointResult) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch }
}
