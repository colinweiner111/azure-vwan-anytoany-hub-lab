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

    [SecureString] $VpnSharedKey,

    [switch] $ResumeExisting
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot

function Assert-AdminPassword {
    param([string] $Password)

    # ARM VM password policy: https://learn.microsoft.com/azure/virtual-machines/linux/faq
    $bannedPasswords = @(
        'abc@123', 'P@$$w0rd', 'P@ssw0rd', 'P@ssword123', 'Pa$$word',
        'pass@word1', 'Password!', 'Password1', 'Password22', 'iloveyou!'
    )
    if ($bannedPasswords -ccontains $Password) {
        throw 'AdminPassword is not permitted by the Azure VM password policy.'
    }
    if ($Password.Length -lt 12 -or $Password.Length -gt 72) {
        throw 'AdminPassword must contain between 12 and 72 characters.'
    }
    if ($Password -cmatch '\p{Cc}') {
        throw 'AdminPassword cannot contain control characters.'
    }
    $classes = 0
    foreach ($pattern in @('[a-z]', '[A-Z]', '[0-9]', '[\W_]')) {
        if ($Password -cmatch $pattern) {
            $classes++
        }
    }
    if ($classes -lt 3) {
        throw 'AdminPassword must contain at least three of lowercase, uppercase, digit, and special characters.'
    }
}

$plainTextAdminPassword = $null
$plainTextVpnSharedKey = $null
$deploymentEnvironmentSet = $false

try {
    if (-not $AdminPassword) {
        $AdminPassword = Read-Host 'Enter VM admin password' -AsSecureString
    }
    # Preserve embedded NULs so the control-character check cannot be bypassed by truncation.
    $passwordBuffer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
    try {
        $plainTextAdminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordBuffer)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBuffer)
    }
    Assert-AdminPassword $plainTextAdminPassword

    if (-not $VpnSharedKey) {
        $VpnSharedKey = Read-Host 'Enter VPN pre-shared key (PSK)' -AsSecureString
    }
    $plainTextVpnSharedKey = [System.Net.NetworkCredential]::new('', $VpnSharedKey).Password
    if ([string]::IsNullOrEmpty($plainTextVpnSharedKey)) {
        throw 'VpnSharedKey cannot be empty.'
    }

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
    $resourceGroupExists = az group exists --name $ResourceGroupName --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or $resourceGroupExists -notin @('true', 'false')) {
        throw "Unable to check whether resource group '$ResourceGroupName' exists."
    }
    if ($resourceGroupExists -eq 'true' -and -not $ResumeExisting) {
        throw "Deployment refused: resource group '$ResourceGroupName' already exists. Use a new group or explicitly pass -ResumeExisting."
    }
    if ($resourceGroupExists -eq 'false' -and $ResumeExisting) {
        throw "Resume refused: resource group '$ResourceGroupName' does not exist."
    }
    $deploymentEnvironmentSet = $true
    $env:AZURE_RESOURCE_GROUP_NAME = $ResourceGroupName
    $env:AZURE_LOCATION1 = $Location
    $env:AZURE_LOCATION2 = $Location2
    $env:AZURE_ADMIN_PASSWORD = $plainTextAdminPassword
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
    if ($deploymentEnvironmentSet) {
        Remove-Item Env:AZURE_RESOURCE_GROUP_NAME -ErrorAction SilentlyContinue
        Remove-Item Env:AZURE_LOCATION1 -ErrorAction SilentlyContinue
        Remove-Item Env:AZURE_LOCATION2 -ErrorAction SilentlyContinue
        Remove-Item Env:AZURE_ADMIN_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:AZURE_VPN_SHARED_KEY -ErrorAction SilentlyContinue
    }
    $plainTextAdminPassword = $null
    $plainTextVpnSharedKey = $null
}
