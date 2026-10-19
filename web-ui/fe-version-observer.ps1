#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Run','Once','Install','Uninstall','Status')][string]$Action='Run',
    [string]$InstallRoot="$env:ProgramData\Rainbow\WebUI",
    [string]$MuscatRoot="$env:ProgramData\Rainbow\Muscat",
    [string]$UpdateInfoUrl='http://localhost:3000/common/deploy/update-info',
    [ValidateRange(5,86400)][int]$IntervalSeconds=60,
    [string]$TaskName='Rainbow-WebUI-Observer'
)
Import-Module (Join-Path $PSScriptRoot 'fe-common.psm1') -Force
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$context=New-FeContext $InstallRoot $MuscatRoot
if ($Action -eq 'Status') {
    Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName,State
    Get-ScheduledTaskInfo -TaskName $TaskName
    if (Test-Path $context.Log) { Get-Content -LiteralPath $context.Log -Tail 25 }
    return
}
Assert-FeAdministrator
if ($Action -eq 'Uninstall') {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    return
}
Initialize-FeContext $context
if ($Action -eq 'Install') {
    foreach ($value in @($PSCommandPath,$InstallRoot,$MuscatRoot,$UpdateInfoUrl)) { if ($value.Contains('"')) { throw 'Task arguments cannot contain quotes.' } }
    $taskArgs='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Run -InstallRoot "{1}" -MuscatRoot "{2}" -UpdateInfoUrl "{3}" -IntervalSeconds {4}' -f $PSCommandPath,$context.Root,[IO.Path]::GetFullPath($MuscatRoot),$UpdateInfoUrl,$IntervalSeconds
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskAction=New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'pwsh.exe') -Argument $taskArgs
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $existing=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -ne $existing) { Stop-ScheduledTask -TaskName $TaskName }
    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Principal $principal -Trigger $trigger -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Installed/started $TaskName; log: $($context.Log)"
    return
}
function Invoke-ObserverDeploy([hashtable]$Parameters) {
    $path=Join-Path $context.Root ('config\observer-request-' + [guid]::NewGuid().ToString('N') + '.clixml')
    $scriptPath=Join-Path $PSScriptRoot 'fe-deploy.ps1'
    @{Script=$scriptPath;Parameters=$Parameters} | Export-Clixml -LiteralPath $path
    try {
        $code='$ErrorActionPreference="Stop"; $r=Import-Clixml -LiteralPath ''' + $path.Replace("'","''") + '''; $a=$r.Parameters; & $r.Script @a'
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded *>&1 | ForEach-Object { Write-FeLog $context ([string]$_) }
        if ($LASTEXITCODE -ne 0) { throw "fe-deploy.ps1 failed (exit $LASTEXITCODE); see observer.log" }
    } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}
function Invoke-ObserverCycle {
    Invoke-FeDocker -Arguments @('info') | Out-Null
    $saved=Read-FeJson $context.Config
    $branch=[string](Get-FeField $saved 'branch' 'main')
    $url=[string](Get-FeField $saved 'updateInfoUrl' $UpdateInfoUrl)
    $zip=Get-ChildItem -LiteralPath $context.Drop -File -Filter '*.zip' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $policy=$null
    try { $policy=Invoke-RestMethod "$($url)?category=web-ui" -TimeoutSec 10 } catch { Write-FeLog $context 'update-info unavailable' }
    $running=@(Get-FeRunningApps)
    if ($null -ne $zip) {
        if ($null -eq $policy) {
            if ($running.Count -gt 0) { Write-FeStatus $context 'waiting' 'policy' 'update-info unavailable; installed Web UI will wait' $zip.Name; return }
        } elseif ([string](Get-FeField $policy 'available' 0) -ne '1') { Write-FeStatus $context 'waiting' 'available' 'available is not 1' $zip.Name; return }
        $signature="$($zip.FullName)|$($zip.Length)|$($zip.LastWriteTimeUtc.Ticks)"
        $stablePath=Join-Path $context.Root 'config\pending-zip.json'
        $pending=Read-FeJson $stablePath
        if ((Get-FeField $pending 'signature' '') -ne $signature -or ([DateTimeOffset]::UtcNow - [DateTimeOffset](Get-FeField $pending 'seenAt' ([DateTimeOffset]::UtcNow))).TotalSeconds -lt 5) {
            if ((Get-FeField $pending 'signature' '') -ne $signature) { Write-FeJson $stablePath @{signature=$signature;seenAt=[DateTimeOffset]::UtcNow.ToString('o')} }
            Write-FeStatus $context 'queued' 'detected' 'Waiting for stable ZIP (minimum 5 seconds)' $zip.Name
            return
        }
        $handle=[IO.File]::Open($zip.FullName,'Open','Read','None'); $handle.Dispose()
        Invoke-ObserverDeploy @{Action='Update';InstallRoot=$context.Root;MuscatRoot=$MuscatRoot;InputPath=$zip.FullName;UpdateInfoUrl=$url;SkipObserver=$true}
        $archive=Join-Path $context.Packages 'observed'
        New-Item -ItemType Directory -Force -Path $archive | Out-Null
        Move-Item -LiteralPath $zip.FullName -Destination (Join-Path $archive ([guid]::NewGuid().ToString('N') + '-' + $zip.Name))
        Write-FeStatus $context 'completed' 'done' 'Offline package applied and archived' $zip.Name
        return
    }
    if ($null -eq $policy -or [string](Get-FeField $policy 'available' 0) -ne '1' -or [string](Get-FeField $policy 'autoUpdate' 0) -ne '1') {
        Write-FeStatus $context 'waiting' 'policy' 'Online update requires available=1 and autoUpdate=1'
        return
    }
    if (!$running.Count) { Write-FeLog $context 'No running ui-* apps to watch'; return }
    $manifest=Get-FeManifest $branch
    $legacy=$null -eq (Get-FeField $manifest 'services')
    $legacyEntries=[ordered]@{}
    $targets=@()
    foreach ($app in $running) {
        $entry=Get-FeEntry $manifest $app
        if ($null -eq $entry -and $legacy) { $entry=Invoke-RestMethod "https://diokjo4dtg1mp.cloudfront.net/web-rainbow-ui/$branch/$app/version.json" -TimeoutSec 30 }
        if ($legacy -and $null -ne $entry) { $legacyEntries[$app]=$entry }
        $local=Read-FeJson (Join-Path $context.Apps "$app\version.json")
        $decision=Get-FeDecision $entry $local $branch $true
        if ($decision -eq 'update') { $targets += $app }
        elseif ($decision -eq 'same') {
            $total=[string](Get-FeField $manifest 'total' (Get-FeField $manifest 'new_version' ''))
            $container=Get-FeContainer "ui-$app"
            $port=Get-FePort (Join-Path $context.Apps $app)
            if ($total -ne [string](Get-FeField $local 'total' '') -or $branch -ne [string](Get-FeField $local 'branch' '') -or (Test-FeRecreate $container $context $app $port)) { $targets += $app }
        }
        elseif ($decision -eq 'blocked') { Write-FeLog $context "[$app] main update blocked (hotfix != true)" }
    }
    if (!$targets.Count) { return }
    if ($legacy) { $manifest | Add-Member -NotePropertyName services -NotePropertyValue ([pscustomobject]$legacyEntries) -Force }
    $snapshot=Join-Path $context.Root ('config\manifest-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-FeJson $snapshot $manifest
    try { Invoke-ObserverDeploy @{Action='Update';InstallRoot=$context.Root;MuscatRoot=$MuscatRoot;Branch=$branch;Apps=$targets;AutoUpdate=$true;ManifestPath=$snapshot;UpdateInfoUrl=$url;SkipObserver=$true} }
    finally { Remove-Item -LiteralPath $snapshot -Force -ErrorAction SilentlyContinue }
}
$lock=[IO.File]::Open((Join-Path $context.Root 'config\observer.lock'),'OpenOrCreate','ReadWrite','None')
try {
    do {
        try { Invoke-ObserverCycle }
        catch { Write-FeStatus $context 'failed' 'check' $_.Exception.Message; if ($Action -eq 'Once') { throw } }
        if ($Action -eq 'Once') { break }
        Start-Sleep -Seconds $IntervalSeconds
    } while ($true)
} finally { $lock.Dispose() }
