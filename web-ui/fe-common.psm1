#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FeField($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Assert-FeName([string]$Name) {
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { throw "Invalid app name: $Name" }
}
function New-FeContext([string]$InstallRoot, [string]$MuscatRoot) {
    $root = [IO.Path]::GetFullPath($InstallRoot)
    $muscat = [IO.Path]::GetFullPath($MuscatRoot)
    [pscustomobject]@{
        Root=$root; Apps=(Join-Path $root 'apps'); Config=(Join-Path $root 'config\install.json')
        Staging=(Join-Path $root 'staging'); Packages=(Join-Path $root 'packages')
        Shared=(Join-Path $root 'shared'); Nginx=(Join-Path $root 'nginx\nginx.conf')
        Drop=(Join-Path $muscat 'data\deploy\web-ui\observe')
        Status=(Join-Path $muscat 'data\deploy\web-ui-status.json')
        Log=(Join-Path $root 'logs\observer.log')
    }
}
function Initialize-FeContext($Context) {
    foreach ($path in @($Context.Apps,$Context.Staging,$Context.Packages,$Context.Shared,$Context.Drop,(Split-Path $Context.Config),(Split-Path $Context.Nginx),(Split-Path $Context.Log))) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
}
function Assert-FeAdministrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run in an administrator PowerShell 7 session (firewall/task configuration).' }
}
function Write-FeJson([string]$Path, $Value) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding utf8
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function Read-FeJson([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
    return $null
}
function Write-FeLog($Context, [string]$Message) {
    $line = '{0:o} {1}' -f [DateTimeOffset]::Now,$Message
    Write-Host $line
    if ((Test-Path $Context.Log) -and (Get-Item $Context.Log).Length -gt 5MB) { Move-Item -LiteralPath $Context.Log -Destination "$($Context.Log).1" -Force }
    Add-Content -LiteralPath $Context.Log -Value $line -Encoding utf8
}
function Write-FeStatus($Context, [string]$State, [string]$Stage, [string]$Message, [string]$Package = '') {
    Write-FeJson $Context.Status @{state=$State;stage=$Stage;message=$Message;package=$Package;updated_at=[DateTimeOffset]::Now.ToString('o')}
    Write-FeLog $Context "$State / $Stage : $Message"
}
function Invoke-FeDocker {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker failed ($LASTEXITCODE): docker $($Arguments -join ' ')" }
    return $result
}
function Get-FeContainer([string]$Name) {
    $raw = & docker container inspect $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return @($raw | ConvertFrom-Json)[0]
}
function Get-FeRunningApps {
    foreach ($name in @(Invoke-FeDocker -Arguments @('ps','--format','{{.Names}}'))) {
        if ($name -cmatch '^ui-(.+)$') { Assert-FeName $Matches[1]; $Matches[1] }
    }
}
function Get-FeManifest([string]$Branch) {
    if ($Branch -notmatch '^[A-Za-z0-9._/-]+$') { throw "Invalid branch: $Branch" }
    Invoke-RestMethod "https://diokjo4dtg1mp.cloudfront.net/web-rainbow-ui/$Branch/version.json" -Headers @{'Cache-Control'='no-cache'} -TimeoutSec 30
}
function Get-FeEntry($Manifest, [string]$App) {
    $map = Get-FeField $Manifest 'services' $Manifest
    $entry = Get-FeField $map $App
    if ($entry -is [string]) { return [pscustomobject]@{version=$entry;hotfix=$false} }
    return $entry
}
function Get-FeVersion($Entry) {
    [string](Get-FeField $Entry 'version' (Get-FeField $Entry 'new_version' (Get-FeField $Entry 'current' '')))
}
function Get-FeDecision($Entry, $Local, [string]$Branch, [bool]$Automatic) {
    $version = Get-FeVersion $Entry
    if (!$version) { return 'missing' }
    if ($version -eq [string](Get-FeField $Local 'current' '') -and !(Get-FeField $Local 'pinned' $false)) { return 'same' }
    if ($Automatic -and $Branch -eq 'main' -and (Get-FeField $Entry 'hotfix' $false) -ne $true) { return 'blocked' }
    return 'update'
}
function Get-FePort([string]$Directory) {
    $info = Read-FeJson (Join-Path $Directory 'hostinfo.json')
    $text = [string](Get-FeField $info 'port' '')
    if ($text -notmatch '^\d{1,5}$' -or [int]$text -lt 1 -or [int]$text -gt 65535) { throw "Invalid hostinfo.json port: $Directory" }
    return [int]$text
}
function Expand-FeZip([string]$Path, [string]$Destination) {
    $base = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $zip = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Path))
    try {
        foreach ($entry in $zip.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $base $entry.FullName))
            if (!$target.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or $entry.FullName.Contains(':') -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw "Unsafe ZIP entry: $($entry.FullName)" }
        }
    } finally { $zip.Dispose() }
    Expand-Archive -LiteralPath $Path -DestinationPath $Destination -Force
}
function Get-FePackageRoot([string]$Directory) {
    $candidates = @((Get-Item -LiteralPath $Directory)) + @(Get-ChildItem -LiteralPath $Directory -Directory -Recurse -Depth 2)
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath (Join-Path $candidate.FullName 'version.json')) -and (Test-Path -LiteralPath (Join-Path $candidate.FullName 'apps') -PathType Container)) { return [pscustomobject]@{Path=$candidate.FullName;Dist=$false} }
    }
    # Dist hotswap requires shell and no formal package manifest.
    foreach ($candidate in $candidates) {
        if (!(Test-Path -LiteralPath (Join-Path $candidate.FullName 'version.json')) -and !(Test-Path -LiteralPath (Join-Path $candidate.FullName 'apps')) -and (Test-Path -LiteralPath (Join-Path $candidate.FullName 'shell\hostinfo.json'))) { return [pscustomobject]@{Path=$candidate.FullName;Dist=$true} }
    }
    throw 'Expected version.json + apps/, or a dist package containing shell/hostinfo.json.'
}
function Get-FeTreeHash([string]$Directory) {
    if (!(Test-Path -LiteralPath $Directory -PathType Container)) { return '' }
    $lines = @(Get-ChildItem -LiteralPath $Directory -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($Directory,$_.FullName).Replace('\','/')
        if ($relative -notin @('version.json','.offline_hash')) { "$relative`:$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
    })
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))))
}
function Copy-FeContents([string]$Source, [string]$Destination, [string]$AllowedParent) {
    $base = [IO.Path]::GetFullPath($AllowedParent).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath($Destination)
    if (!$target.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or $target.TrimEnd('\') -eq $base.TrimEnd('\')) { throw "Unsafe destination: $target" }
    if ([IO.Path]::GetFullPath($Source).TrimEnd('\') -ieq $target.TrimEnd('\')) { throw 'Source and destination must differ.' }
    if (Test-Path -LiteralPath $target) {
        if ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing linked app directory: $target" }
    }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Get-ChildItem -LiteralPath $target -Force | Remove-Item -Force -Recurse
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $target -Recurse -Force
}
function Set-FeFirewall([string]$App, [int]$Port) {
    Assert-FeName $App
    $ruleName = "Rainbow-WebUI-$App-TCP"
    $rule = Get-NetFirewallRule -PolicyStore PersistentStore -Name $ruleName -ErrorAction SilentlyContinue
    $parameters = @{PolicyStore='PersistentStore';Name=$ruleName;Enabled='True';Direction='Inbound';Action='Allow';Profile='Any';Protocol='TCP';LocalPort=$Port;RemoteAddress='Any'}
    if ($null -ne $rule) { Set-NetFirewallRule @parameters | Out-Null }
    else { New-NetFirewallRule @parameters -DisplayName "Web UI $App TCP $Port" | Out-Null }
}
function Test-FeRecreate($Container, $Context, [string]$App, [int]$Port, [string]$Image = 'nginx:alpine') {
    if ($null -eq $Container -or $Container.Config.Image -ne $Image) { return $true }
    $binding = $Container.HostConfig.PortBindings.PSObject.Properties['80/tcp']
    if ($null -eq $binding -or !(@($binding.Value | Where-Object { $_.HostPort -eq [string]$Port -and $_.HostIp -in @('','0.0.0.0') }).Count)) { return $true }
    $pairs = @(@((Join-Path $Context.Apps $App),'/usr/share/nginx/html'),@($Context.Nginx,'/etc/nginx/nginx.conf'),@($Context.Shared,'/usr/share/shared'))
    foreach ($pair in $pairs) {
        $mount = @($Container.Mounts | Where-Object { $_.Destination -eq $pair[1] -and $_.Type -eq 'bind' })
        if ($mount.Count -ne 1 -or [IO.Path]::GetFullPath($mount[0].Source) -ine [IO.Path]::GetFullPath($pair[0])) { return $true }
    }
    $logs = $Container.HostConfig.LogConfig
    if ((Get-FeField $logs.Config 'max-size' '') -ne '10m' -or (Get-FeField $logs.Config 'max-file' '') -ne '5') { return $true }
    return $false
}
function Assert-FePortAvailable([string]$App, [int]$Port) {
    $own = "ui-$App"
    foreach ($name in @(Invoke-FeDocker -Arguments @('ps','--format','{{.Names}}'))) {
        if ($name -eq $own) { continue }
        $other = Get-FeContainer $name
        if ($null -ne $other) {
            $portBindings = $other.HostConfig.PortBindings
            if ($null -eq $portBindings) { continue }
            foreach ($property in $portBindings.PSObject.Properties) {
                if (@($property.Value | Where-Object { $_.HostPort -eq [string]$Port }).Count) { throw "Port $Port is already published by '$name'. Resolve this conflict before deploying '$App'." }
            }
        }
    }
    $ownContainer = Get-FeContainer $own
    $ownsPort = $false
    if ($null -ne $ownContainer -and $ownContainer.State.Running) {
        $bindings = Get-FeField $ownContainer.HostConfig.PortBindings '80/tcp' @()
        $ownsPort = @($bindings | Where-Object { $_.HostPort -eq [string]$Port }).Count -gt 0
    }
    if (!$ownsPort -and @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue).Count) { throw "TCP port $Port already has a Windows listener. No listener/portproxy will be removed automatically." }
}
function Start-FeContainer($Context, [string]$App, [int]$Port, [string]$Image = 'nginx:alpine') {
    $arguments = @('run','-d','--name',"ui-$App",'--restart','unless-stopped','-p',"${Port}:80",
        '--mount',"type=bind,source=$(Join-Path $Context.Apps $App),target=/usr/share/nginx/html",
        '--mount',"type=bind,source=$($Context.Nginx),target=/etc/nginx/nginx.conf,readonly",
        '--mount',"type=bind,source=$($Context.Shared),target=/usr/share/shared",
        '--log-opt','max-size=10m','--log-opt','max-file=5',$Image)
    Invoke-FeDocker -Arguments $arguments | Out-Null
}
function Test-FeAppHealth([string]$App) {
    Invoke-FeDocker -Arguments @('exec',"ui-$App",'nginx','-t') | Out-Null
    for ($attempt=0; $attempt -lt 5; $attempt++) {
        & docker exec "ui-$App" wget -q -O /dev/null http://127.0.0.1/hostinfo.json 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 1
    }
    throw "App health check failed: ui-$App"
}
function Install-FeApp($Context, [string]$App, [string]$Source, [int]$Port, $VersionInfo, [switch]$Dist) {
    Assert-FeName $App
    $destination = Join-Path $Context.Apps $App
    $old = Get-FeContainer "ui-$App"
    $wasRunning = $null -ne $old -and $old.State.Running
    if ($Dist -and ($null -eq $old -or !$old.State.Running)) { throw "Dist hotswap requires a running app: $App" }
    if ($Dist) {
        $oldPort = Get-FePort $destination
        if ($oldPort -ne $Port) { throw "Dist hotswap cannot change port: $App ($oldPort -> $Port)" }
    }
    $recreate = !$Dist -and (Test-FeRecreate $old $Context $App $Port)
    $contentChanged = (Get-FeTreeHash $Source) -ne (Get-FeTreeHash $destination)
    $backup = Join-Path $Context.Staging ("backup-$App-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup | Out-Null
    $hadFiles = Test-Path -LiteralPath $destination
    if ($hadFiles) { Get-ChildItem -LiteralPath $destination -Force | Copy-Item -Destination $backup -Force -Recurse }
    $previousVersion = Read-FeJson (Join-Path $destination 'version.json')
    $renamed = $false; $newAttempt = $false; $started = $false
    $rollbackName = "ui-$App-rollback-$([guid]::NewGuid().ToString('N'))"
    try {
        if ($contentChanged) { Copy-FeContents $Source $destination $Context.Apps }
        if ($Dist) {
            $VersionInfo = [ordered]@{
                branch=(Get-FeField $previousVersion 'branch' '');total=(Get-FeField $previousVersion 'total' '')
                pinned=$true;pinned_at=[DateTimeOffset]::Now.ToString('o');pinned_bin=$App;pinned_from=(Get-FeField $previousVersion 'current')
            }
        }
        if ($recreate) {
            if ($null -ne $old) {
                Invoke-FeDocker -Arguments @('stop',"ui-$App") | Out-Null
                Invoke-FeDocker -Arguments @('rename',"ui-$App",$rollbackName) | Out-Null
                $renamed = $true
            }
            $newAttempt = $true
            Start-FeContainer $Context $App $Port
        } elseif (!$old.State.Running) {
            Invoke-FeDocker -Arguments @('start',"ui-$App") | Out-Null
            $started = $true
        }
        Test-FeAppHealth $App
        Write-FeJson (Join-Path $destination 'version.json') $VersionInfo
        if ($Dist) { if (Test-Path (Join-Path $destination '.offline_hash')) { Remove-Item -LiteralPath (Join-Path $destination '.offline_hash') -Force } }
        else { (Get-FeTreeHash $Source) | Set-Content -LiteralPath (Join-Path $destination '.offline_hash') -Encoding utf8 }
    } catch {
        $failure = $_
        if ($contentChanged) { Copy-FeContents $backup $destination $Context.Apps }
        elseif ($hadFiles) {
            Copy-FeContents $backup $destination $Context.Apps
        }
        if ($newAttempt -and $null -ne (Get-FeContainer "ui-$App")) { Invoke-FeDocker -Arguments @('rm','-f',"ui-$App") | Out-Null }
        if ($renamed) { Invoke-FeDocker -Arguments @('rename',$rollbackName,"ui-$App") | Out-Null }
        if ($wasRunning) { Invoke-FeDocker -Arguments @('start',"ui-$App") | Out-Null }
        elseif ($started) { Invoke-FeDocker -Arguments @('stop',"ui-$App") | Out-Null }
        throw $failure
    }
    if ($renamed) {
        try { Invoke-FeDocker -Arguments @('rm',$rollbackName) | Out-Null } catch { Write-Warning "Deployment succeeded; old stopped container retained: $rollbackName" }
    }
    [pscustomobject]@{App=$App;Port=$Port;FilesChanged=$contentChanged;Recreated=$recreate;Backup=$backup}
}
function Reset-FeAutoUpdate([string]$UpdateInfoUrl) {
    for ($attempt=0; $attempt -lt 6; $attempt++) {
        try { Invoke-RestMethod $UpdateInfoUrl -Method Patch -ContentType 'application/json' -Body '{"category":"web-ui","autoUpdate":0}' -TimeoutSec 5 | Out-Null; return }
        catch { if ($attempt -eq 5) { throw }; Start-Sleep -Seconds 2 }
    }
}
Export-ModuleMember -Function *-Fe*
