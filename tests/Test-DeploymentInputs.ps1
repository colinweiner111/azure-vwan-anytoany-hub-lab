#requires -Version 7.0
<#
.SYNOPSIS
Runs offline deployment-wrapper regression tests without Pester or Azure access.
.DESCRIPTION
Every wrapper invocation runs in a fresh runspace with constant aliases intercepting
az and Read-Host. Only dummy secrets are used.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$wrapperPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'deploy-bicep.ps1'
$script:assertions = 0
$script:cases = 0
$environmentNames = @(
    'AZURE_RESOURCE_GROUP_NAME', 'AZURE_LOCATION1', 'AZURE_LOCATION2',
    'AZURE_ADMIN_PASSWORD', 'AZURE_VPN_SHARED_KEY'
)
$originalEnvironment = @{}
foreach ($name in $environmentNames) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$originalCommands = @{}
foreach ($name in @('az', 'Read-Host')) {
    $originalCommands[$name] = @(Get-Command $name -All -ErrorAction SilentlyContinue | ForEach-Object { "$($_.CommandType):$($_.Definition)" }) -join "`n"
}

function Assert-Test {
    param([bool] $Condition, [string] $Message)
    $script:assertions++
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Invoke-WrapperCase {
    param(
        [string] $Password = 'DummyTest123!',
        [AllowEmptyString()][string] $Psk = 'dummy-vpn-key',
        [switch] $PromptPassword,
        [switch] $PromptPsk,
        [int] $AccountExit = 0,
        [int] $LoginExit = 0,
        [int] $SubscriptionExit = 0,
        [int] $GroupExistsExit = 0,
        [ValidateSet('true', 'false')]
        [string] $GroupExists = 'false',
        [int] $DeploymentExit = 0,
        [switch] $SelectSubscription,
        [switch] $ResumeExisting,
        [switch] $SeedEnvironment
    )
    $script:cases++
    $savedEnvironment = @{}
    foreach ($name in $environmentNames) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $runspace = [PowerShell]::Create()
    try {
        foreach ($name in $environmentNames) {
            if ($SeedEnvironment) {
                [Environment]::SetEnvironmentVariable($name, 'preexisting-dummy-value', 'Process')
            }
            else {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            }
        }
        $options = @{
            Password = $Password; Psk = $Psk
            PromptPassword = [bool] $PromptPassword
            PromptPsk = [bool] $PromptPsk; AccountExit = $AccountExit
            LoginExit = $LoginExit; SubscriptionExit = $SubscriptionExit
            GroupExistsExit = $GroupExistsExit; GroupExists = $GroupExists
            DeploymentExit = $DeploymentExit; SelectSubscription = [bool] $SelectSubscription
            ResumeExisting = [bool] $ResumeExisting
        }
        $runner = {
            param($WrapperPath, $Options, $EnvironmentNames)
            $ErrorActionPreference = 'Stop'
            $global:mock = @{
                Options = $Options
                AzCalls = [System.Collections.Generic.List[object]]::new()
                Prompts = [System.Collections.Generic.List[object]]::new()
                DeploymentEnvironment = $null
            }
            function ConvertTo-DummySecureString([string] $Value) {
                $secure = [System.Security.SecureString]::new()
                foreach ($character in $Value.ToCharArray()) { $secure.AppendChar($character) }
                return $secure
            }
            function global:Invoke-MockAz {
                $arguments = @($args)
                $global:mock.AzCalls.Add($arguments)
                $operation = $arguments[0..1] -join ' '
                $global:LASTEXITCODE = switch ($operation) {
                    'account show' { $global:mock.Options.AccountExit }
                    'login --output' { $global:mock.Options.LoginExit }
                    'account set' { $global:mock.Options.SubscriptionExit }
                    'group exists' {
                        $global:LASTEXITCODE = $global:mock.Options.GroupExistsExit
                        return $global:mock.Options.GroupExists
                    }
                    'deployment sub' {
                        if ($arguments[2] -ne 'create') { throw 'Unexpected mocked az deployment operation.' }
                        $global:mock.DeploymentEnvironment = @{}
                        foreach ($name in $EnvironmentNames) {
                            $global:mock.DeploymentEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
                        }
                        $global:mock.Options.DeploymentExit
                    }
                    default { throw 'Unexpected mocked az operation.' }
                }
            }
            function global:Invoke-MockReadHost {
                param([string] $Prompt, [switch] $AsSecureString)
                $global:mock.Prompts.Add(@{ Prompt = $Prompt; Secure = [bool] $AsSecureString })
                if (-not $AsSecureString) { throw 'An insecure prompt was attempted.' }
                switch ($Prompt) {
                    'Enter VM admin password' { ConvertTo-DummySecureString $global:mock.Options.Password }
                    'Enter VPN pre-shared key (PSK)' { ConvertTo-DummySecureString $global:mock.Options.Psk }
                    default { throw 'An unexpected prompt was attempted.' }
                }
            }
            Set-Alias -Name az -Value Invoke-MockAz -Scope Global -Option Constant
            Set-Alias -Name Read-Host -Value Invoke-MockReadHost -Scope Global -Option Constant
            $parameters = @{ ResourceGroupName = 'dummy-rg'; Location = 'eastus'; Location2 = 'westus' }
            if (-not $Options.PromptPassword) { $parameters.AdminPassword = ConvertTo-DummySecureString $Options.Password }
            if (-not $Options.PromptPsk) { $parameters.VpnSharedKey = ConvertTo-DummySecureString $Options.Psk }
            if ($Options.SelectSubscription) { $parameters.SubscriptionId = '00000000-0000-0000-0000-000000000001' }
            if ($Options.ResumeExisting) { $parameters.ResumeExisting = $true }
            $failure = $null
            $output = [System.Collections.Generic.List[string]]::new()
            try { . $WrapperPath @parameters *>&1 | ForEach-Object { $output.Add([string] $_) } }
            catch { $failure = $_.Exception.Message }
            $remainingEnvironment = @{}
            foreach ($name in $EnvironmentNames) {
                $remainingEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }
            [pscustomobject]@{
                Failure = $failure
                Output = $output -join "`n"
                AzCalls = $global:mock.AzCalls.ToArray()
                Prompts = $global:mock.Prompts.ToArray()
                DeploymentEnvironment = $global:mock.DeploymentEnvironment
                RemainingEnvironment = $remainingEnvironment
                PlaintextCleared = (
                    $null -eq (Get-Variable plainTextAdminPassword -ValueOnly -ErrorAction SilentlyContinue) -and
                    $null -eq (Get-Variable plainTextVpnSharedKey -ValueOnly -ErrorAction SilentlyContinue)
                )
            }
        }
        $null = $runspace.AddScript($runner.ToString()).AddArgument($wrapperPath).AddArgument($options).AddArgument($environmentNames)
        $results = $runspace.Invoke()
        Assert-Test ($runspace.Streams.Error.Count -eq 0) 'Isolated harness execution succeeded.'
        Assert-Test ($results.Count -eq 1) 'Wrapper returned exactly one harness result.'
        $result = $results[0]
        Assert-Test $result.PlaintextCleared 'Plaintext variables were cleared on every exit path.'
        $logs = "$($result.Output)`n$($result.Failure)"
        foreach ($secret in @($Password, $Psk)) {
            if ($secret.Length -gt 0) {
                Assert-Test (-not $logs.Contains($secret)) 'No dummy secret was written to output or errors.'
            }
        }
        foreach ($call in $result.AzCalls) {
            $command = $call -join ' '
            foreach ($secret in @($Password, $Psk)) {
                if (-not [string]::IsNullOrWhiteSpace($secret)) {
                    Assert-Test (-not $command.Contains($secret)) 'Secrets were not passed as CLI arguments.'
                }
            }
        }
        return $result
    }
    finally {
        $runspace.Dispose()
        foreach ($name in $environmentNames) {
            if ($null -eq $savedEnvironment[$name]) {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            }
            else {
                [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
            }
        }
    }
}

function Assert-Rejected {
    param($Result, [string] $ExpectedError, [switch] $Early)
    Assert-Test ($null -ne $Result.Failure -and $Result.Failure.Contains($ExpectedError)) 'Expected input or operation failure was returned.'
    Assert-Test ($null -eq $Result.DeploymentEnvironment) 'Rejected inputs never reached deployment.'
    if ($Early) {
        Assert-Test ($Result.AzCalls.Count -eq 0) 'Explicit invalid inputs fail before Azure authentication.'
    }
}

function Assert-Succeeded {
    param($Result)
    Assert-Test ($null -eq $Result.Failure) 'Valid inputs succeeded.'
    Assert-Test ($null -ne $Result.DeploymentEnvironment) 'Valid inputs reached only mocked deployment.'
    foreach ($name in $environmentNames) {
        Assert-Test ($null -eq $Result.RemainingEnvironment[$name]) 'Deployment environment was removed after completion.'
    }
}

try {
    foreach ($length in @(11, 12, 72, 73)) {
        $result = Invoke-WrapperCase -Password ('Aa1' + ('x' * ($length - 3)))
        if ($length -in @(12, 72)) { Assert-Succeeded $result }
        else { Assert-Rejected $result 'between 12 and 72' -Early }
    }
    foreach ($password in @('aaaaaaaaaaaa', 'AAAAAAAAAAAA', '111111111111', '____________',
            'aaaaaaAAAAAA', 'aaaaaa111111', 'aaaaaa!!!!!!', 'AAAAAA111111', 'AAAAAA!!!!!!', '111111!!!!!!')) {
        Assert-Rejected (Invoke-WrapperCase -Password $password) 'at least three' -Early
    }
    foreach ($password in @('aaaaAAAA1111', 'aaaaAAAA!!!!', 'aaaa1111!!!!', 'AAAA1111!!!!',
            'aaaa1111____', 'AAAA1111____', 'aaaaAAAA____', 'aaAA11!!!!!!')) {
        Assert-Succeeded (Invoke-WrapperCase -Password $password)
    }
    foreach ($password in @('abc@123', 'P@$$w0rd', 'P@ssw0rd', 'P@ssword123', 'Pa$$word',
            'pass@word1', 'Password!', 'Password1', 'Password22', 'iloveyou!')) {
        Assert-Rejected (Invoke-WrapperCase -Password $password) 'not permitted' -Early
    }
    foreach ($control in @(0, 9, 10, 13, 31, 127, 133, 159)) {
        Assert-Rejected (Invoke-WrapperCase -Password ('DummyTest123!' + [char] $control)) 'control characters' -Early
    }
    $result = Invoke-WrapperCase -PromptPassword -PromptPsk
    Assert-Succeeded $result
    Assert-Test ($result.Prompts.Count -eq 2) 'Both omitted secrets were securely prompted.'
    Assert-Test (@($result.Prompts | Where-Object { -not $_.Secure }).Count -eq 0) 'Every prompt used AsSecureString.'
    Assert-Rejected (Invoke-WrapperCase -PromptPassword -Password 'too-short') 'between 12 and 72' -Early
    Assert-Rejected (Invoke-WrapperCase -Password '') 'between 12 and 72' -Early
    Assert-Rejected (Invoke-WrapperCase -Password 'too-short') 'between 12 and 72' -Early
    Assert-Rejected (Invoke-WrapperCase -Psk '') 'VpnSharedKey cannot be empty' -Early
    Assert-Rejected (Invoke-WrapperCase -PromptPsk -Psk '') 'VpnSharedKey cannot be empty' -Early
    Assert-Succeeded (Invoke-WrapperCase -Psk ' ') # Preserve the existing nonempty, not nonwhitespace, PSK rule.
    $result = Invoke-WrapperCase -AccountExit 1
    Assert-Succeeded $result
    Assert-Test (($result.AzCalls[1] -join ' ') -eq 'login --output none') 'Missing authentication triggered mocked login.'
    Assert-Rejected (Invoke-WrapperCase -AccountExit 1 -LoginExit 1) 'Unable to sign in'
    Assert-Rejected (Invoke-WrapperCase -SelectSubscription -SubscriptionExit 1) 'Unable to select'
    Assert-Rejected (Invoke-WrapperCase -GroupExistsExit 1) 'Unable to check whether resource group'
    Assert-Rejected (Invoke-WrapperCase -GroupExists 'true') 'already exists'
    Assert-Rejected (Invoke-WrapperCase -ResumeExisting) 'does not exist'
    $result = Invoke-WrapperCase -GroupExists 'true' -ResumeExisting
    Assert-Succeeded $result
    Assert-Test (@($result.AzCalls | Where-Object { ($_ -join ' ') -eq 'group exists --name dummy-rg --output tsv' }).Count -eq 1) 'Resume verifies the existing resource group.'
    $result = Invoke-WrapperCase -SelectSubscription -SeedEnvironment
    Assert-Succeeded $result
    Assert-Test (($result.AzCalls[1] -join ' ') -eq 'account set --subscription 00000000-0000-0000-0000-000000000001') 'Subscription selection was preserved.'
    Assert-Test ($result.Prompts.Count -eq 0) 'Explicit inputs avoid prompts.'
    Assert-Test ($result.DeploymentEnvironment.AZURE_RESOURCE_GROUP_NAME -ceq 'dummy-rg') 'Resource group environment was preserved.'
    Assert-Test ($result.DeploymentEnvironment.AZURE_LOCATION1 -ceq 'eastus' -and $result.DeploymentEnvironment.AZURE_LOCATION2 -ceq 'westus') 'Both region environment values were preserved.'
    Assert-Test ($result.DeploymentEnvironment.AZURE_ADMIN_PASSWORD -ceq 'DummyTest123!' -and $result.DeploymentEnvironment.AZURE_VPN_SHARED_KEY -ceq 'dummy-vpn-key') 'SecureString secrets reached only the deployment environment.'
    $deploymentArguments = $result.AzCalls[-1] -join ' '
    Assert-Test ($deploymentArguments.Contains('deployment sub create') -and $deploymentArguments.Contains('adminUsername=azureuser') -and $deploymentArguments.Contains('main.bicepparam')) 'Existing deployment arguments were preserved.'
    $result = Invoke-WrapperCase -DeploymentExit 1 -SeedEnvironment
    Assert-Test ($result.Failure -eq 'Azure deployment failed.') 'CLI deployment failure propagated.'
    Assert-Test ($null -ne $result.DeploymentEnvironment) 'Deployment failure came from the mocked deployment.'
    foreach ($name in $environmentNames) {
        Assert-Test ($null -eq $result.RemainingEnvironment[$name]) 'Environment was cleaned after deployment failure.'
    }
    $result = Invoke-WrapperCase -Password 'too-short' -SeedEnvironment
    Assert-Rejected $result 'between 12 and 72' -Early
    foreach ($name in $environmentNames) {
        Assert-Test ($result.RemainingEnvironment[$name] -eq 'preexisting-dummy-value') 'Early validation leaves untouched environment values alone.'
    }
    foreach ($name in $environmentNames) {
        Assert-Test ([Environment]::GetEnvironmentVariable($name, 'Process') -ceq $originalEnvironment[$name]) "Harness restored caller environment variable $name."
    }
    foreach ($name in $originalCommands.Keys) {
        $current = @(Get-Command $name -All -ErrorAction SilentlyContinue | ForEach-Object { "$($_.CommandType):$($_.Definition)" }) -join "`n"
        Assert-Test ($current -ceq $originalCommands[$name]) 'Isolated mocks did not alter caller command state.'
    }
    Write-Host "PASS: $script:cases deployment input cases; $script:assertions assertions (offline mocks only)."
}
catch {
    Write-Error "FAIL after $script:cases cases and $script:assertions assertions: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
