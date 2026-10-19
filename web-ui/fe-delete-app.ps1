#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory)][string[]]$Apps,
    [string]$InstallRoot="$env:ProgramData\Rainbow\WebUI",
    [string]$MuscatRoot="$env:ProgramData\Rainbow\Muscat",
    [switch]$RemoveFiles
)
Import-Module (Join-Path $PSScriptRoot 'fe-common.psm1') -Force
$ErrorActionPreference='Stop'
if (!$WhatIfPreference) { Assert-FeAdministrator }
$context=New-FeContext $InstallRoot $MuscatRoot
foreach ($app in $Apps) { Assert-FeName $app }
$lock=$null
if (!$WhatIfPreference) { $lock=[IO.File]::Open((Join-Path $context.Root 'config\deploy.lock'),'OpenOrCreate','ReadWrite','None') }
try {
    foreach ($app in $Apps) {
        if (!$PSCmdlet.ShouldProcess("ui-$app",'Remove app container and its firewall rule; optionally remove app files')) { continue }
        if ($null -ne (Get-FeContainer "ui-$app")) { Invoke-FeDocker -Arguments @('rm','-f',"ui-$app") | Out-Null }
        $rule=Get-NetFirewallRule -Name "Rainbow-WebUI-$app-TCP" -ErrorAction SilentlyContinue
        if ($null -ne $rule) { $rule | Remove-NetFirewallRule }
        if ($RemoveFiles) {
            $parent=[IO.Path]::GetFullPath($context.Apps).TrimEnd('\') + '\'
            $path=[IO.Path]::GetFullPath((Join-Path $context.Apps $app))
            if (!$path.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or $path.TrimEnd('\') -eq $parent.TrimEnd('\')) { throw "Unsafe path: $path" }
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
        $saved=Read-FeJson $context.Config
        if ($null -ne $saved) { $saved.apps=@($saved.apps | Where-Object { $_ -ne $app }); Write-FeJson $context.Config $saved }
    }
} finally { if ($null -ne $lock) { $lock.Dispose() } }
