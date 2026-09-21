#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Location,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Location2,

    [string] $AdminUsername = 'azureuser',

    [SecureString] $AdminPassword,

    [string] $SshSourceAddressPrefix,

    [SecureString] $VpnSharedKey
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required.'
}

az account show --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    az login --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to sign in to Azure.'
    }
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to select the requested Azure subscription.'
    }
}

if (-not $AdminPassword) {
    $AdminPassword = Read-Host 'Enter VM admin password' -AsSecureString
}

if (-not $VpnSharedKey) {
    $VpnSharedKey = Read-Host 'Enter VPN pre-shared key (PSK)' -AsSecureString
}

if ([string]::IsNullOrWhiteSpace($SshSourceAddressPrefix)) {
    $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim()
    $SshSourceAddressPrefix = "$publicIp/32"
}

$plainTextAdminPassword = [System.Net.NetworkCredential]::new('', $AdminPassword).Password
$plainTextVpnSharedKey = [System.Net.NetworkCredential]::new('', $VpnSharedKey).Password
if ($plainTextAdminPassword.Length -lt 12) {
    throw 'AdminPassword must contain at least 12 characters.'
}
if ([string]::IsNullOrEmpty($plainTextVpnSharedKey)) {
    throw 'VpnSharedKey cannot be empty.'
}

try {
    $env:AZURE_RESOURCE_GROUP_NAME = $ResourceGroupName
    $env:AZURE_LOCATION1 = $Location
    $env:AZURE_LOCATION2 = $Location2
    $env:AZURE_ADMIN_PASSWORD = $plainTextAdminPassword
    $env:AZURE_SSH_SOURCE_PREFIX = $SshSourceAddressPrefix
    $env:AZURE_VPN_SHARED_KEY = $plainTextVpnSharedKey

    az deployment sub create `
        --name "vwan-anytoany-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
        --location $Location `
        --template-file (Join-Path $projectRoot 'main.bicep') `
        --parameters (Join-Path $projectRoot 'main.bicepparam') `
        --parameters adminUsername=$AdminUsername

    if ($LASTEXITCODE -ne 0) {
        throw 'Azure deployment failed.'
    }
}
finally {
    Remove-Item Env:AZURE_RESOURCE_GROUP_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_LOCATION1 -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_LOCATION2 -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_ADMIN_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_SSH_SOURCE_PREFIX -ErrorAction SilentlyContinue
    Remove-Item Env:AZURE_VPN_SHARED_KEY -ErrorAction SilentlyContinue
    $plainTextAdminPassword = $null
    $plainTextVpnSharedKey = $null
}
