#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Apps,
    [string]$InstallRoot="$env:ProgramData\Rainbow\WebUI",
    [string]$MuscatRoot="$env:ProgramData\Rainbow\Muscat",
    [string]$Branch
)
& (Join-Path $PSScriptRoot 'fe-deploy.ps1') -Action Update @PSBoundParameters
