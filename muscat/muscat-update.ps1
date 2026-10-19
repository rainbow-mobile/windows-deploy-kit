#requires -Version 7.0
<# Windows equivalent of muscat-update.sh; requires sibling muscat-deploy.ps1.
No changes: preserve container. Service changes: supervisor restart only.
Image ID / enabled services / mounts / published ports change: recreate container.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramData\Rainbow\Muscat",
    [ValidatePattern('^[A-Za-z0-9._/-]+$')][string]$Branch = '',
    [string[]]$Services = @(),
    [string]$InputPath = '',
    [switch]$AutoUpdate,
    [switch]$ForceDownload,
    [string]$DeployScript = (Join-Path $PSScriptRoot 'muscat-deploy.ps1')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$script:InvocationParameters = @{} + $PSBoundParameters
# Import only function definitions, never the deployment entry point.
$tokens = $null; $parseErrors = $null
$deployAst = [Management.Automation.Language.Parser]::ParseFile($DeployScript, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Unable to parse muscat-deploy.ps1' }
foreach ($definition in $deployAst.EndBlock.Statements) {
    if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
$script:ConfigDirectory = Join-Path $InstallRoot 'config'
$script:ConfigPath = Join-Path $script:ConfigDirectory 'install.json'
$script:DataDirectory = Join-Path $InstallRoot 'data'
$script:ServicesDirectory = Join-Path $InstallRoot 'services'
$script:PackagesDirectory = Join-Path $InstallRoot 'packages'
$script:StagingDirectory = Join-Path $InstallRoot 'staging'
$config = Load-Configuration
if ($null -eq $config) { throw 'Muscat is not installed. Run muscat-deploy.ps1 -Action Install first.' }
$script:Branch = if ($Branch) { $Branch } else { [string]$config.branch }
$script:ContainerName = [string]$config.containerName
$script:ImageName = [string]$config.imageName
$script:HttpPort = [int]$config.httpPort
$script:PublishedPorts = [int[]]@($config.publishedPorts)
Assert-WindowsAmd64
Assert-Command docker
Initialize-Directories
$updateLock = [IO.File]::Open((Join-Path $script:ConfigDirectory 'update.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
function Get-TreeDigest([string]$Root) {
    if (!(Test-Path -LiteralPath $Root -PathType Container)) { return '' }
    $items = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\','/')
        $relative + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    })
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($items -join "`n"))))
}
function Copy-ServiceContents([string]$Source, [string]$Destination) {
    # Preserve the bind-mounted directory itself. Call only with verified service paths.
    $base = [IO.Path]::GetFullPath($script:ServicesDirectory).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath($Destination)
    if (!$target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or $target.TrimEnd('\') -eq $base.TrimEnd('\')) { throw "Unsafe service destination: $target" }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Get-ChildItem -LiteralPath $target -Force | Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $target -Recurse -Force
}
function Test-Recreate($Container, [string]$DesiredImage, [string[]]$Enabled) {
    if ($null -eq $Container -or !$Container.State.Running -or $Container.Image -ne $DesiredImage) { return $true }
    $csv = 'RB_ENABLED_SERVICES=' + (($Enabled | Sort-Object -Unique) -join ',')
    if ($csv -notin @($Container.Config.Env)) { return $true }
    foreach ($pair in @(@($script:DataDirectory,'/app/data'), @($script:ServicesDirectory,'/app/services'))) {
        $mount = @($Container.Mounts | Where-Object { $_.Destination -eq $pair[1] -and $_.Type -eq 'bind' })
        if ($mount.Count -ne 1 -or [IO.Path]::GetFullPath($mount[0].Source) -ine [IO.Path]::GetFullPath($pair[0])) { return $true }
        if ($pair[1] -eq '/app/services' -and $mount[0].RW) { return $true }
    }
    $expectedBindings = @('3000/tcp') + @($script:PublishedPorts | Where-Object { $_ -ne $script:HttpPort } | ForEach-Object { "$_/tcp" })
    foreach ($bindingName in @($Container.HostConfig.PortBindings.PSObject.Properties.Name)) {
        if ($bindingName -notin $expectedBindings) { return $true }
    }
    foreach ($port in @(@($script:HttpPort) + @($script:PublishedPorts) | Sort-Object -Unique)) {
        $containerPort = if ($port -eq $script:HttpPort) { 3000 } else { $port }
        $binding = $Container.HostConfig.PortBindings.PSObject.Properties["$containerPort/tcp"]
        if ($null -eq $binding -or !(@($binding.Value | Where-Object { $_.HostPort -eq [string]$port -and $_.HostIp -in @('','0.0.0.0') }).Count)) { return $true }
    }
    return $false
}
try {
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop Linux engine is unavailable.' }
    Set-MuscatFirewall
    $fallback = 'offline'
    if (!$InputPath) { $package = Resolve-OnlinePackage; $InputPath = $package.Path; $fallback = $package.TotalVersion }
    $root = Expand-DeploymentPackage $InputPath
    $total = Get-PackageTotalVersion $root $fallback
    $packageManifestPath = Join-Path $root 'services\version.json'
    if (!(Test-Path $packageManifestPath)) { $packageManifestPath = Join-Path $root 'version.json' }
    if (Test-Path $packageManifestPath) {
        $packageManifest = Get-Content -Raw -LiteralPath $packageManifestPath | ConvertFrom-Json
        if ($null -ne $packageManifest.PSObject.Properties['branch'] -and $packageManifest.branch) {
            if ($packageManifest.branch -notmatch '^[A-Za-z0-9._/-]+$') { throw 'Invalid package branch' }
            if ($AutoUpdate -and $packageManifest.branch -ne $script:Branch) { throw 'Automatic update package branch mismatch' }
            $script:Branch = [string]$packageManifest.branch
        }
    }
    $selected = @(Resolve-SelectedServices $root $config)
    if (!$selected.Count) { throw 'No services selected.' }
    $enabled = @(@($config.enabledServices) + $selected | Where-Object { $_ -ne 'host' } | Sort-Object -Unique)
    $changed = @()
    foreach ($service in $selected) {
        $source = Join-Path $root "services\$service"
        if (!(Test-Path -LiteralPath (Join-Path $source "$service.amd64.bin") -PathType Leaf)) { throw "Missing service binary: $service" }
        if ((Get-TreeDigest $source) -ne (Get-TreeDigest (Join-Path $script:ServicesDirectory $service))) { $changed += $service }
    }
    if ($AutoUpdate -and $script:Branch -eq 'main') {
        $manifestPath = Join-Path $root 'services\version.json'
        if (!(Test-Path $manifestPath)) { $manifestPath = Join-Path $root 'version.json' }
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        foreach ($service in $changed) {
            $servicesProperty = $manifest.PSObject.Properties['services']
            $entry = if ($null -ne $servicesProperty) { $servicesProperty.Value.PSObject.Properties[$service] } else { $null }
            if ($null -eq $entry -or $null -eq $entry.Value.PSObject.Properties['hotfix'] -or $entry.Value.hotfix -ne $true) { throw "main automatic update blocked (hotfix != true): $service" }
        }
    }
    $container = $null
    if (Test-ContainerExists) { $container = (& docker container inspect $script:ContainerName | ConvertFrom-Json)[0] }
    $imageArchive = @('muscat-image.amd64.tar.gz','muscat-image.amd64.tar','muscat-image.tar.gz','muscat-image.tar') | ForEach-Object { Join-Path $root "muscat\$_" } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (!$imageArchive) { throw 'Package has no amd64 Muscat image archive.' }
    $imageHash = (Get-FileHash -LiteralPath $imageArchive -Algorithm SHA256).Hash
    $imageStatePath = Join-Path $script:ConfigDirectory 'update-image.json'
    $oldImageState = if (Test-Path $imageStatePath) { Get-Content -Raw $imageStatePath | ConvertFrom-Json } else { $null }
    $currentImage = & docker image inspect $script:ImageName --format '{{.Id}}' 2>$null
    $imageExists = $LASTEXITCODE -eq 0
    if (!$imageExists -or $null -eq $oldImageState -or $oldImageState.archiveHash -ne $imageHash -or $oldImageState.imageId -ne $currentImage) { Import-MuscatImage $root }
    $desiredImage = & docker image inspect $script:ImageName --format '{{.Id}}'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect loaded image.' }
    $recreate = Test-Recreate $container ([string]$desiredImage) $enabled
    # Complete backups before touching any running service.
    $backupRoot = Join-Path $script:StagingDirectory ('update-backup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backupRoot | Out-Null
    $existed = @{}; $touched = @()
    foreach ($service in $changed) {
        $destination = Join-Path $script:ServicesDirectory $service
        $existed[$service] = Test-Path -LiteralPath $destination
        if ($existed[$service]) { Copy-Item -LiteralPath $destination -Destination (Join-Path $backupRoot $service) -Recurse -Force }
    }
    try {
        if ($recreate -and $null -ne $container) { Invoke-Docker -Arguments @('stop', $script:ContainerName) }
        foreach ($service in $changed) {
            if (!$recreate) { Invoke-Docker -Arguments @('exec',$script:ContainerName,'supervisorctl','stop',$service) }
            $touched += $service
            Copy-ServiceContents (Join-Path $root "services\$service") (Join-Path $script:ServicesDirectory $service)
        }
        if ($recreate) {
            Start-MuscatContainer $enabled
            
        } else {
            foreach ($service in $changed) { Invoke-Docker -Arguments @('exec',$script:ContainerName,'supervisorctl','start',$service) }
        }
        # supervisorctl may return before the startup grace period expires.
        if ($changed.Count -or $recreate) {
            Start-Sleep -Seconds 5
            $checkServices = if ($recreate) { $enabled } else { $changed }
            foreach ($service in $checkServices) {
                $status = & docker exec $script:ContainerName supervisorctl status $service
                if ($LASTEXITCODE -ne 0 -or ($status -join ' ') -notmatch '\sRUNNING\s') { throw "Service failed after update: $service ($status)" }
            }
        }
        Save-Configuration $enabled $total
        @{archiveHash=$imageHash; imageId=[string]$desiredImage} | ConvertTo-Json | Set-Content -LiteralPath "$imageStatePath.tmp" -Encoding utf8
        Move-Item -LiteralPath "$imageStatePath.tmp" -Destination $imageStatePath -Force
    } catch {
        $updateError = $_
        Write-Warning "Update failed; restoring service backups from $backupRoot"
        if (Test-ContainerExists) { & docker stop $script:ContainerName | Out-Null }
        foreach ($service in $touched) {
            $destination = Join-Path $script:ServicesDirectory $service
            if ($existed[$service]) { Copy-ServiceContents (Join-Path $backupRoot $service) $destination }
            else {
                # Only clear the known, validated service destination; preserve mount parent.
                $empty = Join-Path $backupRoot 'empty'; New-Item -ItemType Directory -Force $empty | Out-Null
                Copy-ServiceContents $empty $destination
            }
        }
        if ($null -ne $container) {
            # Restore previous image tag and topology if recreation had occurred.
            if ($recreate) { Invoke-Docker -Arguments @('image','tag',[string]$container.Image,$script:ImageName); Start-MuscatContainer @($config.enabledServices) }
            else { Invoke-Docker -Arguments @('start',$script:ContainerName) }
        }
        $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ConfigPath -Encoding utf8
        throw $updateError
    }
    Write-Host "Update completed: total=$total; changed=$($changed -join ','); recreated=$recreate"
    Write-Host "Backup: $backupRoot"
} finally { $updateLock.Dispose() }