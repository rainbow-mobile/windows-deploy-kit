[CmdletBinding()]
param(
    [ValidateSet("Install", "Update", "Start", "Stop", "Restart", "Status")]
    [string] $Action = "Install",

    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string] $Branch = "main",

    [string] $InstallRoot = "$env:ProgramData\Rainbow\Muscat",

    [string[]] $Services = @(),

    [string] $InputPath = "",

    [int] $HttpPort = 3000,

    [int[]] $PublishedPorts = @(7447, 17447),

    [string] $ContainerName = "muscat",

    [string] $ImageName = "muscat:latest",

    [switch] $ForceDownload
)

if ($Action -eq 'Update') {
    $updater = Join-Path $PSScriptRoot 'muscat-update.ps1'
    if (!(Test-Path -LiteralPath $updater -PathType Leaf)) { throw "Update script not found: $updater" }
    $updateParameters = @{ InstallRoot=$InstallRoot; Services=$Services; InputPath=$InputPath; ForceDownload=$ForceDownload; DeployScript=$PSCommandPath }
    if ($PSBoundParameters.ContainsKey('Branch')) { $updateParameters.Branch=$Branch }
    foreach ($option in @('ContainerName','ImageName','HttpPort','PublishedPorts')) {
        if ($PSBoundParameters.ContainsKey($option)) { throw "Update uses the saved installation settings; configure $option through Install." }
    }
    & $updater @updateParameters
    return
}
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:InvocationParameters = @{} + $PSBoundParameters

$script:ConfigDirectory = Join-Path $InstallRoot "config"
$script:ConfigPath = Join-Path $script:ConfigDirectory "install.json"
$script:DataDirectory = Join-Path $InstallRoot "data"
$script:ServicesDirectory = Join-Path $InstallRoot "services"
$script:PackagesDirectory = Join-Path $InstallRoot "packages"
$script:StagingDirectory = Join-Path $InstallRoot "staging"
$script:ContainerName = $ContainerName
$script:ImageName = $ImageName
$script:HttpPort = $HttpPort
$script:Branch = $Branch
$script:PublishedPorts = $PublishedPorts

function Write-Step([string] $Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Assert-WindowsAmd64 {
    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne "X64") {
        throw "현재는 Windows amd64만 지원합니다."
    }
}

function Assert-Command([string] $Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "필수 명령어를 찾을 수 없습니다: $Name"
    }
}

function Invoke-Docker {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $Arguments
    )

    & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker 명령 실패: docker $($Arguments -join ' ')"
    }
}

function Set-MuscatFirewall {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "방화벽 설정에 관리자 권한이 필요합니다. 관리자 PowerShell에서 다시 실행하세요."
    }
    if ($script:HttpPort -lt 1 -or $script:HttpPort -gt 65535) {
        throw "올바르지 않은 HTTP 포트: $($script:HttpPort)"
    }

    # Web UI ports are firewall allowances only; they are not Muscat Docker bindings.
    $firewallPorts = @(@($script:HttpPort) + @($script:PublishedPorts) + @(8180, 5174, 5176, 5177) | Sort-Object -Unique)
    foreach ($port in $firewallPorts) {
        if ($port -lt 1 -or $port -gt 65535) { throw "올바르지 않은 방화벽 포트: $port" }
    }
    Write-Step "Windows 방화벽 TCP 포트 허용: $($firewallPorts -join ', ') (LocalSubnet)"
    $ruleName = "Rainbow-Muscat-$($script:ContainerName)-HTTP"
    $existing = Get-NetFirewallRule -PolicyStore PersistentStore -Name $ruleName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Set-NetFirewallRule -PolicyStore PersistentStore -Name $ruleName -Enabled True -Direction Inbound -Action Allow -Profile Any -Protocol TCP -LocalPort $firewallPorts -RemoteAddress LocalSubnet | Out-Null
    }
    else {
        New-NetFirewallRule -PolicyStore PersistentStore -Name $ruleName -DisplayName "Muscat TCP ($($script:ContainerName))" -Enabled True -Direction Inbound -Action Allow -Profile Any -Protocol TCP -LocalPort $firewallPorts -RemoteAddress LocalSubnet | Out-Null
    }
}
function Test-ContainerExists {
    & docker container inspect $script:ContainerName *> $null
    return $LASTEXITCODE -eq 0
}

function Test-ContainerRunning {
    if (-not (Test-ContainerExists)) {
        return $false
    }

    $running = & docker container inspect --format '{{.State.Running}}' $script:ContainerName
    return $LASTEXITCODE -eq 0 -and $running.Trim() -eq "true"
}

function Stop-MuscatContainer {
    if (Test-ContainerExists) {
        Write-Step "Muscat 컨테이너 제거"
        Invoke-Docker -Arguments @("rm", "-f", $script:ContainerName)
    }
}

function Initialize-Directories {
    foreach ($directory in @(
        $script:ConfigDirectory,
        $script:DataDirectory,
        $script:ServicesDirectory,
        $script:PackagesDirectory,
        $script:StagingDirectory
    )) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
}

function Save-Configuration([string[]] $EnabledServices, [string] $TotalVersion) {
    $configuration = [ordered]@{
        schemaVersion   = 1
        branch          = $script:Branch
        installRoot     = $InstallRoot
        containerName   = $script:ContainerName
        imageName       = $script:ImageName
        httpPort        = $script:HttpPort
        publishedPorts  = @($script:PublishedPorts)
        enabledServices = @($EnabledServices)
        totalVersion    = $TotalVersion
        updatedAt       = [DateTime]::UtcNow.ToString("o")
    }

    $temporary = "$($script:ConfigPath).tmp"
    $configuration | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8NoBOM $temporary
    Move-Item -Force $temporary $script:ConfigPath
}

function Load-Configuration {
    if (-not (Test-Path $script:ConfigPath -PathType Leaf)) {
        return $null
    }

    return Get-Content -Raw $script:ConfigPath | ConvertFrom-Json
}

function Apply-SavedConfiguration {
    $configuration = Load-Configuration
    if ($null -eq $configuration) {
        return $null
    }

    if (-not $script:InvocationParameters.ContainsKey("Branch")) {
        $script:Branch = [string] $configuration.branch
    }
    if (-not $script:InvocationParameters.ContainsKey("ContainerName")) {
        $script:ContainerName = [string] $configuration.containerName
    }
    if (-not $script:InvocationParameters.ContainsKey("ImageName")) {
        $script:ImageName = [string] $configuration.imageName
    }
    if (-not $script:InvocationParameters.ContainsKey("HttpPort")) {
        $script:HttpPort = [int] $configuration.httpPort
    }
    if (-not $script:InvocationParameters.ContainsKey("PublishedPorts") -and
        $null -ne $configuration.PSObject.Properties["publishedPorts"]) {
        $script:PublishedPorts = [int[]] @($configuration.publishedPorts)
    }

    return $configuration
}

function Get-RemoteJson([string[]] $Uris) {
    $lastError = $null
    foreach ($uri in $Uris) {
        try {
            return Invoke-RestMethod -Uri $uri -Headers @{ "Cache-Control" = "no-cache" }
        }
        catch {
            $lastError = $_
        }
    }

    throw "매니페스트 다운로드 실패: $($Uris -join ', ')`n$lastError"
}

function Download-File([string[]] $Uris, [string] $Destination) {
    $lastError = $null
    foreach ($uri in $Uris) {
        try {
            Write-Host "다운로드: $uri"
            Invoke-WebRequest -Uri $uri -OutFile $Destination -UseBasicParsing
            return
        }
        catch {
            $lastError = $_
            Remove-Item -Force $Destination -ErrorAction SilentlyContinue
        }
    }

    throw "파일 다운로드 실패: $($Uris -join ', ')`n$lastError"
}

function Resolve-OnlinePackage {
    $s3Base = "https://diokjo4dtg1mp.cloudfront.net/muscat/$($script:Branch)"
    $repoBase = "https://raw.githubusercontent.com/rainbow-mobile/rainbow-release-apps/$($script:Branch)/muscat"
    $manifest = Get-RemoteJson @("$s3Base/version.json", "$repoBase/version.json")
    $totalVersion = if ($manifest.total) { [string] $manifest.total } else { [string] $manifest.new_version }

    if ([string]::IsNullOrWhiteSpace($totalVersion)) {
        throw "원격 version.json에 total/new_version이 없습니다."
    }
    if ($totalVersion -notmatch '^[A-Za-z0-9._-]+$') {
        throw "올바르지 않은 총 버전 값입니다: $totalVersion"
    }

    $packagePath = Join-Path $script:PackagesDirectory "$totalVersion.amd64.zip"
    if ($ForceDownload -or -not (Test-Path $packagePath -PathType Leaf)) {
        $temporary = "$packagePath.download"
        Download-File @(
            "$s3Base/$totalVersion.amd64.zip"
        ) $temporary
        Move-Item -Force $temporary $packagePath
    }
    else {
        Write-Host "기존 패키지 사용: $packagePath"
    }

    return [pscustomobject]@{
        Path         = $packagePath
        TotalVersion = $totalVersion
    }
}

function Expand-DeploymentPackage([string] $PackagePath) {
    $resolved = (Resolve-Path $PackagePath).Path
    if (Test-Path $resolved -PathType Container) {
        return $resolved
    }

    if ([IO.Path]::GetExtension($resolved) -ne ".zip") {
        throw "입력 파일은 ZIP이어야 합니다: $resolved"
    }

    $extractDirectory = Join-Path $script:StagingDirectory ([guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $extractDirectory | Out-Null
    Expand-Archive -Path $resolved -DestinationPath $extractDirectory -Force

    $candidates = @($extractDirectory) + @(
        Get-ChildItem -Path $extractDirectory -Directory -Recurse -Depth 2 |
            Select-Object -ExpandProperty FullName
    )
    foreach ($candidate in $candidates) {
        if ((Test-Path (Join-Path $candidate "services") -PathType Container) -and
            (Test-Path (Join-Path $candidate "muscat") -PathType Container)) {
            return $candidate
        }
    }

    throw "ZIP에서 services/ 및 muscat/ 디렉터리를 찾지 못했습니다: $resolved"
}

function Get-PackageTotalVersion([string] $PackageRoot, [string] $Fallback) {
    foreach ($manifestPath in @(
        (Join-Path $PackageRoot "services\version.json"),
        (Join-Path $PackageRoot "version.json")
    )) {
        if (Test-Path $manifestPath -PathType Leaf) {
            $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
            if ($manifest.total) { return [string] $manifest.total }
            if ($manifest.new_version) { return [string] $manifest.new_version }
        }
    }
    return $Fallback
}

function Resolve-SelectedServices([string] $PackageRoot, $SavedConfiguration) {
    $available = @(
        Get-ChildItem -Path (Join-Path $PackageRoot "services") -Directory |
            Where-Object { $_.Name -ne "host" } |
            Select-Object -ExpandProperty Name
    )

    $requested = @($Services | Where-Object { $_ -and $_ -ne "host" } | Sort-Object -Unique)
    if ($requested.Count -eq 0 -and $null -ne $SavedConfiguration) {
        $requested = @($SavedConfiguration.enabledServices | Where-Object { $_ -and $_ -ne "host" })
    }
    if ($requested.Count -eq 0) {
        $requested = $available
    }

    foreach ($service in $requested) {
        if ($service -notmatch '^[A-Za-z0-9._-]+$') {
            throw "올바르지 않은 서비스 이름: $service"
        }
        if ($service -notin $available) {
            throw "패키지에 서비스가 없습니다: $service"
        }
    }

    return @($requested | Sort-Object -Unique)
}

function Install-Services([string] $PackageRoot, [string[]] $SelectedServices) {
    Write-Step "서비스 설치: $($SelectedServices -join ', ')"
    foreach ($service in $SelectedServices) {
        $source = Join-Path $PackageRoot "services\$service"
        $binary = Join-Path $source "$service.amd64.bin"
        if (-not (Test-Path $binary -PathType Leaf)) {
            throw "서비스 바이너리가 없습니다: $binary"
        }

        $destination = Join-Path $script:ServicesDirectory $service
        $old = "$destination.old"
        Remove-Item -Recurse -Force $old -ErrorAction SilentlyContinue
        if (Test-Path $destination) {
            Move-Item $destination $old
        }
        try {
            Copy-Item -Recurse -Force $source $destination
            Remove-Item -Recurse -Force $old -ErrorAction SilentlyContinue
        }
        catch {
            Remove-Item -Recurse -Force $destination -ErrorAction SilentlyContinue
            if (Test-Path $old) { Move-Item $old $destination }
            throw
        }
    }
}

function Import-MuscatImage([string] $PackageRoot) {
    $muscatDirectory = Join-Path $PackageRoot "muscat"
    $archives = @(
        "muscat-image.amd64.tar.gz",
        "muscat-image.amd64.tar",
        "muscat-image.tar.gz",
        "muscat-image.tar"
    )

    $archive = $null
    foreach ($name in $archives) {
        $candidate = Join-Path $muscatDirectory $name
        if (Test-Path $candidate -PathType Leaf) {
            $archive = $candidate
            break
        }
    }

    if ($null -eq $archive) {
        throw "패키지에 amd64 Muscat Docker 이미지가 없습니다: $muscatDirectory"
    }

    $checksumPath = "$archive.sha256"
    if (Test-Path $checksumPath -PathType Leaf) {
        $expected = ((Get-Content -Raw $checksumPath).Trim() -split '\s+')[0].ToLowerInvariant()
        $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
        if ($expected -ne $actual) {
            throw "Muscat 이미지 SHA-256 불일치: $archive"
        }
    }

    Write-Step "Muscat Docker 이미지 로드"
    Invoke-Docker -Arguments @("load", "-i", $archive)
    & docker image inspect $script:ImageName *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "로드된 Docker 이미지에 '$($script:ImageName)' 태그가 없습니다."
    }
}

function Start-MuscatContainer([string[]] $EnabledServices) {
    if ($EnabledServices.Count -eq 0) {
        throw "실행할 서비스가 없습니다."
    }

    Stop-MuscatContainer
    Write-Step "Muscat 컨테이너 시작"

    $dataPath = (Resolve-Path $script:DataDirectory).Path
    $servicesPath = (Resolve-Path $script:ServicesDirectory).Path
    $enabledCsv = $EnabledServices -join ","

    $arguments = @(
        "run", "-d",
        "--name", $script:ContainerName,
        "--restart", "unless-stopped",
        "--cpus", "2",
        "--memory", "3g",
        "-p", "$($script:HttpPort):3000",
        "--mount", "type=bind,source=$dataPath,target=/app/data",
        "--mount", "type=bind,source=$servicesPath,target=/app/services,readonly",
        "-e", "RB_MODE=prod",
        "-e", "RB_BIN_DIR=/app/services",
        "-e", "RB_ENABLED_SERVICES=$enabledCsv",
        "-e", "RB_ZENOH_UNIXSOCK_DIR="
    )
    foreach ($port in @($script:PublishedPorts | Sort-Object -Unique)) {
        if ($port -le 0 -or $port -gt 65535) {
            throw "올바르지 않은 publish 포트: $port"
        }
        if ($port -ne $script:HttpPort) {
            $arguments += @("-p", "${port}:${port}")
        }
    }
    $arguments += $script:ImageName
    Invoke-Docker -Arguments $arguments
}



function Show-MuscatStatus {
    $configuration = Load-Configuration
    Write-Host "설치 경로: $InstallRoot"
    Write-Host "설정 파일: $($script:ConfigPath)"
    if ($null -ne $configuration) {
        Write-Host "브랜치: $($configuration.branch)"
        Write-Host "총 버전: $($configuration.totalVersion)"
        Write-Host "서비스: $($configuration.enabledServices -join ', ')"
    }

    if (Test-ContainerExists) {
        & docker ps -a --filter "name=^/$($script:ContainerName)$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}"
    }
    else {
        Write-Host "컨테이너가 없습니다: $($script:ContainerName)"
    }
}

Assert-WindowsAmd64
Assert-Command docker
Initialize-Directories
$savedConfiguration = Apply-SavedConfiguration

& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker Desktop이 실행 중이지 않거나 Linux 컨테이너 엔진에 연결할 수 없습니다."
}

if ($Action -in @('Install', 'Update', 'Start', 'Restart')) {
    Set-MuscatFirewall
}

switch ($Action) {
    "Stop" {
        Stop-MuscatContainer
        break
    }
    "Status" {
        Show-MuscatStatus
        break
    }
    "Start" {
        if ($null -eq $savedConfiguration) { throw "설치 설정이 없습니다. 먼저 Install을 실행하세요." }
        Start-MuscatContainer @($savedConfiguration.enabledServices)
        if ($script:InvocationParameters.ContainsKey("PublishedPorts")) {
            Save-Configuration @($savedConfiguration.enabledServices) ([string]$savedConfiguration.totalVersion)
        }
        
        Show-MuscatStatus
        break
    }
    "Restart" {
        if ($null -eq $savedConfiguration) { throw "설치 설정이 없습니다. 먼저 Install을 실행하세요." }
        Start-MuscatContainer @($savedConfiguration.enabledServices)
        if ($script:InvocationParameters.ContainsKey("PublishedPorts")) {
            Save-Configuration @($savedConfiguration.enabledServices) ([string]$savedConfiguration.totalVersion)
        }
        
        Show-MuscatStatus
        break
    }
    { $_ -in @("Install", "Update") } {
        Write-Step "Windows용 Muscat 배포 시작 (host 제외)"

        $totalVersion = "offline"
        if ([string]::IsNullOrWhiteSpace($InputPath)) {
            $onlinePackage = Resolve-OnlinePackage
            $packagePath = $onlinePackage.Path
            $totalVersion = $onlinePackage.TotalVersion
        }
        else {
            $packagePath = $InputPath
        }

        $packageRoot = Expand-DeploymentPackage $packagePath
        $totalVersion = Get-PackageTotalVersion $packageRoot $totalVersion
        $selectedServices = Resolve-SelectedServices $packageRoot $savedConfiguration

        # bind mount 대상 교체와 이미지 갱신 전에 컨테이너를 내린다.
        Stop-MuscatContainer
        Install-Services $packageRoot $selectedServices
        Import-MuscatImage $packageRoot
        Save-Configuration $selectedServices $totalVersion
        Start-MuscatContainer $selectedServices
        

        Write-Host "`n배포 완료: http://localhost:$($script:HttpPort)" -ForegroundColor Green
        Show-MuscatStatus
        break
    }
}