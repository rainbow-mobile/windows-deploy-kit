[CmdletBinding()]
param([string]$InstallRoot="$env:ProgramData\Rainbow\WebUI",[switch]$Follow)
Get-Content -LiteralPath (Join-Path $InstallRoot 'logs\observer.log') -Tail 50 -Wait:$Follow
