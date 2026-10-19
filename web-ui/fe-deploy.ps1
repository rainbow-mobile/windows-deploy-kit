#requires -Version 7.0
<#
Windows port of fe-deploy.sh. Requires Docker Desktop in Linux-container mode.
Install includes shell/assets/common; Update targets saved/running apps.
Plan only reads version metadata. Offline accepts total ZIP/directory or shell-containing dist ZIP.
#>
[CmdletBinding()]
param(
    [ValidateSet('Install','Update','Plan','Status')][string]$Action='Install',
    [ValidatePattern('^[A-Za-z0-9._/-]+$')][string]$Branch='main',
    [string[]]$Apps=@(),
    [string]$InstallRoot="$env:ProgramData\Rainbow\WebUI",
    [string]$MuscatRoot="$env:ProgramData\Rainbow\Muscat",
    [string]$InputPath='',
    [string]$ManifestPath='',
    [switch]$AutoUpdate,
    [switch]$ForceDownload,
    [switch]$SkipObserver,
    [string]$FO='',
    [string]$UpdateInfoUrl='http://localhost:3000/common/deploy/update-info'
)
Import-Module (Join-Path $PSScriptRoot 'fe-common.psm1') -Force
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$context = New-FeContext $InstallRoot $MuscatRoot
$saved = Read-FeJson $context.Config
if (!$PSBoundParameters.ContainsKey('Branch') -and $null -ne $saved) { $Branch=[string]$saved.branch }
if (!$PSBoundParameters.ContainsKey('FO') -and $null -ne $saved) { $FO=[string](Get-FeField $saved 'fo' '') }
if (!$PSBoundParameters.ContainsKey('UpdateInfoUrl') -and $null -ne $saved) { $UpdateInfoUrl=[string](Get-FeField $saved 'updateInfoUrl' $UpdateInfoUrl) }
if ($Action -eq 'Status') {
    Invoke-FeDocker -Arguments @('ps','-a','--filter','name=ui-','--format','table {{.Names}}\t{{.Status}}\t{{.Ports}}')
    $saved
    return
}
if ($InputPath -and $ManifestPath) { throw 'Use InputPath or ManifestPath, not both. Offline packages carry their own manifest.' }
if ($Action -ne 'Plan') {
    Assert-FeAdministrator
    Invoke-FeDocker -Arguments @('info') | Out-Null
    Initialize-FeContext $context
}
$lock=$null
if ($Action -ne 'Plan') { $lock=[IO.File]::Open((Join-Path $context.Root 'config\deploy.lock'),'OpenOrCreate','ReadWrite','None') }
try {
    $dist=$false; $packageRoot=''; $manifest=$null; $offline=[bool]$InputPath
    if ($offline) {
        if ($Action -eq 'Plan' -and !(Test-Path -LiteralPath $InputPath -PathType Container)) { throw 'For a read-only offline Plan, extract the ZIP and pass its directory.' }
        if (Test-Path -LiteralPath $InputPath -PathType Container) { $expanded=(Resolve-Path -LiteralPath $InputPath).Path }
        else {
            $expanded=Join-Path $context.Staging ([guid]::NewGuid().ToString('N'))
            Expand-FeZip $InputPath $expanded
        }
        $package=Get-FePackageRoot $expanded
        $packageRoot=$package.Path; $dist=$package.Dist
        if (!$dist) {
            $manifest=Read-FeJson (Join-Path $packageRoot 'version.json')
            $Branch=[string](Get-FeField $manifest 'branch' $Branch)
        }
    } elseif ($ManifestPath) { $manifest=Read-FeJson $ManifestPath }
    else { $manifest=Get-FeManifest $Branch }
    if ($Branch -notmatch '^[A-Za-z0-9._/-]+$') { throw 'Invalid package/configured branch.' }
    if ($dist) {
        $targets=@(Get-ChildItem -LiteralPath $packageRoot -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'hostinfo.json') } | Select-Object -ExpandProperty Name)
        if ($Apps.Count) { $targets=@($targets | Where-Object { $_ -in $Apps }) }
    } elseif ($offline) {
        $available=@(Get-ChildItem -LiteralPath (Join-Path $packageRoot 'apps') -Directory | Select-Object -ExpandProperty Name)
        $targets=if ($Apps.Count) { @($Apps) } else { @($available) }
    } elseif ($Action -eq 'Install') { $targets=@(@('shell','assets','common') + $Apps | Sort-Object -Unique) }
    elseif ($Apps.Count) { $targets=@($Apps | Sort-Object -Unique) }
    else {
        $targets=@(Get-FeField $saved 'apps' @())
        if (!$targets.Count) { $targets=@(Get-FeRunningApps) }
        if (!$targets.Count -and $Action -eq 'Plan') { $targets=@('shell','assets','common') }
    }
    $targets=@($targets)
    if (!$targets.Count) { throw 'No apps selected or installed.' }
    foreach ($app in $targets) { Assert-FeName $app }
    $total=[string](Get-FeField $manifest 'total' (Get-FeField $manifest 'new_version' ''))
    $prepared=@(); $results=@(); $ports=@{}
    $stage=if ($Action -ne 'Plan') { Join-Path $context.Staging ('deploy-' + [guid]::NewGuid().ToString('N')) } else { '' }
    if ($stage) { New-Item -ItemType Directory -Path $stage | Out-Null }
    foreach ($app in $targets) {
        $local=Read-FeJson (Join-Path $context.Apps "$app\version.json")
        $entry=Get-FeEntry $manifest $app
        if (!$dist -and $null -eq $entry -and !$offline -and $null -eq (Get-FeField $manifest 'services')) {
            $entry=Invoke-RestMethod "https://diokjo4dtg1mp.cloudfront.net/web-rainbow-ui/$Branch/$app/version.json" -TimeoutSec 30
        }
        $decision=if ($dist) { 'dist' } else { Get-FeDecision $entry $local $Branch ([bool]$AutoUpdate) }
        if ($decision -eq 'missing') { throw "No manifest version for app: $app" }
        if ($decision -eq 'blocked') { Write-Host "[$app] main auto-update blocked (hotfix != true)"; continue }
        $version=Get-FeVersion $entry
        if ($version -and $version -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid app version: $app/$version" }
        if ($Action -eq 'Plan') { [pscustomobject]@{App=$app;Current=(Get-FeField $local 'current' '');Desired=$version;Decision=$decision;Branch=$Branch;Total=$total}; continue }
        $destination=Join-Path $context.Apps $app
        $source=''
        if ($offline) {
            $source=if ($dist) { Join-Path $packageRoot $app } else { Join-Path $packageRoot "apps\$app" }
            if (!(Test-Path -LiteralPath $source -PathType Container)) { throw "App absent from offline package: $app" }
        } elseif ($decision -eq 'same' -and (Test-Path -LiteralPath (Join-Path $destination 'hostinfo.json'))) {
            # Same version still repairs a missing/stopped/misconfigured container without downloading.
            $source=Join-Path $stage $app
            Copy-Item -LiteralPath $destination -Destination $source -Recurse -Force
        } else {
            $cacheDir=Join-Path $context.Packages $app
            New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
            # Branch may contain slashes; use a hash for a filesystem-safe cache key.
            $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$Branch/$app/$version")))
            $zip=Join-Path $cacheDir "$key.zip"
            if ($ForceDownload -or !(Test-Path -LiteralPath $zip)) {
                Invoke-WebRequest "https://diokjo4dtg1mp.cloudfront.net/web-rainbow-ui/$Branch/$app/$version.zip" -OutFile "$zip.download" -TimeoutSec 600
                Move-Item -LiteralPath "$zip.download" -Destination $zip -Force
            }
            $source=Join-Path $stage $app
            Expand-FeZip $zip $source
        }
        $port=Get-FePort $source
        if ($ports.ContainsKey($port)) { throw "Apps '$app' and '$($ports[$port])' both specify port $port." }
        $ports[$port]=$app
        if ($dist) {
            $container=Get-FeContainer "ui-$app"
            if ($null -eq $container -or !$container.State.Running) { Write-Warning "Skipping dist for app without a running container: $app"; continue }
            if ((Get-FePort $destination) -ne $port) { throw "Dist cannot change '$app' port." }
        }
        Assert-FePortAvailable $app $port
        $prepared += [pscustomobject]@{App=$app;Source=$source;Port=$port;Version=$version}
    }
    if ($Action -eq 'Plan') { return }
    if (!$prepared.Count) {
        if ($dist) { throw 'No running apps matched this dist package.' }
        Write-Host 'No permitted updates.'
        return
    }
    if (!(Test-Path -LiteralPath $context.Nginx)) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'nginx\nginx.conf') -Destination $context.Nginx }
    & docker image inspect nginx:alpine *> $null
    if ($LASTEXITCODE -ne 0) { Invoke-FeDocker -Arguments @('pull','nginx:alpine') | Out-Null }
    # Validate every package/port before firewall/container/file mutations.
    foreach ($item in $prepared) { Set-FeFirewall $item.App $item.Port }
    $completed=@(Get-FeField $saved 'apps' @())
    foreach ($item in $prepared) {
        Write-FeStatus $context 'running' 'app-deploy' "Deploying $($item.App)" $InputPath
        $info=@{current=$item.Version;branch=$Branch;total=$total}
        $results += Install-FeApp $context $item.App $item.Source $item.Port $info -Dist:$dist
        $completed=@($completed + $item.App | Sort-Object -Unique)
        # Record each successful app; failed apps keep their previous version/files.
        Write-FeJson $context.Config @{schemaVersion=1;branch=$Branch;fo=$FO;apps=$completed;muscatRoot=[IO.Path]::GetFullPath($MuscatRoot);updateInfoUrl=$UpdateInfoUrl;updatedAt=[DateTimeOffset]::Now.ToString('o')}
    }
    if ($offline) {
        try { Reset-FeAutoUpdate $UpdateInfoUrl }
        catch { Write-FeStatus $context 'failed' 'policy' 'Files deployed; failed to disable online autoUpdate. Retry before enabling observer.' $InputPath; throw }
    }
    Write-FeStatus $context 'completed' 'done' 'Web UI deployment completed' $InputPath
    $results | Format-Table App,Port,FilesChanged,Recreated
    if ($Action -eq 'Install' -and !$SkipObserver) {
        & (Join-Path $PSScriptRoot 'fe-version-observer.ps1') -Action Install -InstallRoot $context.Root -MuscatRoot $MuscatRoot -UpdateInfoUrl $UpdateInfoUrl
    }
    if ($FO -and $PSBoundParameters.ContainsKey('FO')) {
        & (Join-Path $PSScriptRoot 'browser.ps1') -Action Install -InstallRoot $context.Root
    }
} catch {
    if ($Action -ne 'Plan') { Write-FeStatus $context 'failed' 'deploy' $_.Exception.Message $InputPath }
    throw
} finally { if ($null -ne $lock) { $lock.Dispose() } }
