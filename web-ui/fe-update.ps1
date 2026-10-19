#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$InstallRoot="$env:ProgramData\Rainbow\WebUI",
    [string]$MuscatRoot="$env:ProgramData\Rainbow\Muscat",
    [string]$Branch,
    [string[]]$Apps=@(),
    [string]$InputPath='',
    [string]$ManifestPath='',
    [switch]$AutoUpdate,
    [switch]$ForceDownload,
    [string]$UpdateInfoUrl='http://localhost:3000/common/deploy/update-info'
)
& (Join-Path $PSScriptRoot 'fe-deploy.ps1') -Action Update @PSBoundParameters
