#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Run','Install','Uninstall')][string]$Action='Run',
    [string]$InstallRoot="$env:ProgramData\Rainbow\WebUI",
    [string]$BrowserPath='',
    [string]$TaskName='Rainbow-WebUI-Kiosk'
)
Import-Module (Join-Path $PSScriptRoot 'fe-common.psm1') -Force
$ErrorActionPreference='Stop'
if ($Action -eq 'Uninstall') { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; return }
$config=Read-FeJson (Join-Path $InstallRoot 'config\install.json')
$fo=[string](Get-FeField $config 'fo' '')
if (!$fo) { throw 'No FO configured. Pass -FO /S100 to fe-deploy.ps1 when kiosk is wanted.' }
if (!$BrowserPath) {
    $BrowserPath=@("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe","$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (!$BrowserPath -or !(Test-Path -LiteralPath $BrowserPath)) { throw 'Microsoft Edge not found. Specify -BrowserPath pointing to msedge.exe.' }
if ($Action -eq 'Install') {
    foreach ($value in @($PSCommandPath,$InstallRoot,$BrowserPath)) { if ($value.Contains('"')) { throw 'Task arguments cannot contain quotes.' } }
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $arguments='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Run -InstallRoot "{1}" -BrowserPath "{2}"' -f $PSCommandPath,[IO.Path]::GetFullPath($InstallRoot),$BrowserPath
    $taskAction=New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'pwsh.exe') -Argument $arguments
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $trigger -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    return
}
$shell=Join-Path $InstallRoot 'apps\shell'
$port=Get-FePort $shell
$url="http://localhost:$port/$($fo.TrimStart('/'))"
if ($url.Contains('?')) { $url += '&' } else { $url += '?' }
$url += 'rb_mode=' + [Uri]::EscapeDataString([string]$config.branch)
if ($url.Contains('"')) { throw 'FO cannot contain quotes.' }
# Visible browser is intentional only for the explicit kiosk action/FO option.
Start-Process -FilePath $BrowserPath -ArgumentList @('--kiosk',('"' + $url + '"'),'--edge-kiosk-type=fullscreen','--no-first-run') -WindowStyle Normal
