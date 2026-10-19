#requires -Version 7.0
<#
Windows Muscat observer. Run in an elevated PowerShell session.
Install registers a highest-privilege task for the current user at logon (Docker Desktop user session).
Run: foreground polling; Once: one check; Status/Uninstall: scheduled task management.
#>
[CmdletBinding()]
param(
    [ValidateSet('Run','Once','Install','Uninstall','Status')][string]$Action = 'Run',
    [string]$InstallRoot = "$env:ProgramData\Rainbow\Muscat",
    [Alias('DeployScript')][string]$UpdateScript = '',
    [ValidateRange(5,86400)][int]$IntervalSeconds = 60,
    [string]$TaskName = 'Rainbow-Muscat-Observer'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (!$UpdateScript) { $UpdateScript = Join-Path $PSScriptRoot 'muscat-update.ps1' }
$UpdateScript = [IO.Path]::GetFullPath($UpdateScript)
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$configPath = Join-Path $InstallRoot 'config\install.json'
$dropDirectory = Join-Path $InstallRoot 'data\deploy\muscat\observe'
$statusPath = Join-Path $InstallRoot 'data\deploy\muscat-status.json'
$logPath = Join-Path $InstallRoot 'logs\observer.log'
function Get-Field($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Write-Log([string]$Message) {
    $line = '{0:o} {1}' -f [DateTimeOffset]::Now, $Message
    Write-Host $line
    if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 5MB) { Move-Item -LiteralPath $logPath -Destination "$logPath.1" -Force }
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
}
function Write-State([string]$State, [string]$Stage, [string]$Message, [string]$Package = '') {
    $value = @{state=$State; stage=$Stage; message=$Message; package=$Package; updated_at=[DateTimeOffset]::Now.ToString('o')}
    $value | ConvertTo-Json | Set-Content -LiteralPath "$statusPath.tmp" -Encoding utf8
    Move-Item -LiteralPath "$statusPath.tmp" -Destination $statusPath -Force
    Write-Log "$State / $Stage : $Message"
}
function Get-Manifest([string]$Branch) {
    if ($Branch -notmatch '^[A-Za-z0-9._/-]+$') { throw 'Invalid configured branch' }
    foreach ($base in @("https://diokjo4dtg1mp.cloudfront.net/muscat/$Branch", "https://raw.githubusercontent.com/rainbow-mobile/rainbow-release-apps/$Branch/muscat")) {
        try { return Invoke-RestMethod "$base/version.json" -Headers @{'Cache-Control'='no-cache'} -TimeoutSec 30 } catch { Write-Log "Manifest request failed: $($_.Exception.Message)" }
    }
    throw 'Unable to fetch manifest'
}
function Invoke-Update($Config, [string]$Package = '') {
    $deployArgs = @{InstallRoot=$InstallRoot; Branch=[string]$Config.branch; Services=[string[]]@($Config.enabledServices)}
    if ($Package) { $deployArgs.InputPath = $Package }
    if (!$script:OfflineUpdate) { $deployArgs.AutoUpdate = $true }
    # Separate process keeps deployment script scope/preferences isolated and checks its exit code.
    $requestPath = Join-Path $InstallRoot ('config\observer-request-' + [guid]::NewGuid().ToString('N') + '.clixml')
    @{Script=$UpdateScript; Arguments=$deployArgs} | Export-Clixml -LiteralPath $requestPath
    try {
        $env:MUSCAT_OBSERVER_REQUEST = $requestPath
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command '$r = Import-Clixml -LiteralPath $env:MUSCAT_OBSERVER_REQUEST; $a = $r.Arguments; & $r.Script @a' *>&1 | ForEach-Object { Write-Log ([string]$_) }
        if ($LASTEXITCODE -ne 0) { throw "Deployment exited with code $LASTEXITCODE" }
    } finally { Remove-Item -LiteralPath $requestPath -ErrorAction SilentlyContinue; Remove-Item Env:MUSCAT_OBSERVER_REQUEST -ErrorAction SilentlyContinue }
}
function Invoke-Cycle {
    if (!(Test-Path $configPath)) { throw 'Install Muscat first: install.json is missing' }
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    $uri = "http://localhost:$($config.httpPort)/common/deploy/update-info"
    $zip = Get-ChildItem -LiteralPath $dropDirectory -Filter '*.zip' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    try { $policy = Invoke-RestMethod "$($uri)?category=muscat" -TimeoutSec 10 } catch {
        Write-State 'waiting' 'policy' 'update-info unavailable; retry next cycle'
        return
    }
    if ([string](Get-Field $policy 'available' 0) -ne '1') { Write-State 'waiting' 'available' 'available is not 1'; return }
    if ($null -ne $zip) {
        # Require unchanged size/time across two polls, plus an exclusive open, before consuming an upload.
        $signature = "$($zip.FullName)|$($zip.Length)|$($zip.LastWriteTimeUtc.Ticks)"
        if ($script:PendingZip -ne $signature) { $script:PendingZip = $signature; Write-State 'queued' 'detected' 'Waiting for stable ZIP' $zip.Name; return }
        $handle = [IO.File]::Open($zip.FullName, 'Open', 'Read', 'None'); $handle.Dispose()
        Write-State 'running' 'update' 'Offline deployment started' $zip.Name
        $script:OfflineUpdate = $true
        Invoke-Update $config $zip.FullName
        # Move successful packages out of the queue; failed packages stay for retry.
        $archiveDir = Join-Path $InstallRoot 'packages\observed'
        New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null
        Move-Item -LiteralPath $zip.FullName -Destination (Join-Path $archiveDir (([guid]::NewGuid().ToString('N')) + '-' + $zip.Name))
        $disabled = $false
        for ($attempt=0; $attempt -lt 6; $attempt++) {
            try { Invoke-RestMethod $uri -Method Patch -ContentType 'application/json' -Body '{"category":"muscat","autoUpdate":0}' -TimeoutSec 5 | Out-Null; $disabled=$true; break } catch { Start-Sleep -Seconds 2 }
        }
        if (!$disabled) { Write-State 'failed' 'policy' 'Deployment succeeded but autoUpdate reset failed'; return }
        Write-State 'completed' 'done' 'Offline deployment completed' $zip.Name
        return
    }
    if ([string](Get-Field $policy 'autoUpdate' 0) -ne '1') { Write-State 'waiting' 'autoUpdate' 'Online autoUpdate is disabled'; return }
    $manifest = Get-Manifest ([string]$config.branch)
    $total = [string](Get-Field $manifest 'total' (Get-Field $manifest 'new_version' ''))
    if ($total -notmatch '^[A-Za-z0-9._-]+$') { throw 'Invalid manifest total version' }
    if ($total -eq [string]$config.totalVersion) { Write-Log "Already current: $total"; return }
    if ($config.branch -eq 'main') {
        # Full-package deploy cannot safely apply a mixture of permitted and blocked services.
        $services = Get-Field $manifest 'services'
        foreach ($name in @($config.enabledServices)) {
            $entry = Get-Field $services $name
            if ((Get-Field $entry 'hotfix' $false) -ne $true) { Write-State 'waiting' 'hotfix' "Full-package main update requires hotfix=true for every enabled service; blocked: $name"; return }
        }
    }
    # Pin the ZIP URL to this manifest snapshot; do not let deploy fetch a newer manifest.
    $packagePath = Join-Path $InstallRoot "packages\$total.amd64.zip"
    if (!(Test-Path $packagePath)) {
        $url = "https://diokjo4dtg1mp.cloudfront.net/muscat/$($config.branch)/$total.amd64.zip"
        Invoke-WebRequest $url -OutFile "$packagePath.download" -TimeoutSec 600
        Move-Item -LiteralPath "$packagePath.download" -Destination $packagePath -Force
    }
    Write-State 'running' 'update' "Online deployment started: $total"
    $script:OfflineUpdate = $false
    Invoke-Update $config $packagePath
    Write-State 'completed' 'done' "Online deployment completed: $total"
}
if ($Action -eq 'Status') { Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo; if (Test-Path $logPath) { Get-Content $logPath -Tail 20 }; return }
if ($Action -eq 'Uninstall') { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; return }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script in an administrator PowerShell session.' }
if (!(Test-Path -LiteralPath $UpdateScript -PathType Leaf)) { throw "Deploy script not found: $UpdateScript. Use -UpdateScript to specify its path." }
foreach ($dir in @($dropDirectory, (Split-Path $logPath), (Split-Path $statusPath), (Join-Path $InstallRoot 'packages'))) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
if ($Action -eq 'Install') {
    foreach ($value in @($PSCommandPath,$InstallRoot,$UpdateScript)) { if ($value.Contains('"')) { throw 'Paths cannot contain quotes' } }
    $taskArgs = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Run -InstallRoot "{1}" -UpdateScript "{2}" -IntervalSeconds {3}' -f $PSCommandPath,$InstallRoot,$UpdateScript,$IntervalSeconds
    $taskAction = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'pwsh.exe') -Argument $taskArgs
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Observer installed and started: $TaskName. Log: $logPath"
    return
}
$lockPath = Join-Path $InstallRoot 'config\observer.lock'
$lock = [IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
$script:PendingZip = ''
try {
    do {
        try { Invoke-Cycle } catch { Write-State 'failed' 'check' $_.Exception.Message }
        if ($Action -eq 'Once') { break }
        Start-Sleep -Seconds $IntervalSeconds
    } while ($true)
} finally { $lock.Dispose() }