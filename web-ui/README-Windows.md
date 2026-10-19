# Web UI — Windows PowerShell 7

`rainbow-deploy-kit/web-ui`의 Linux 스크립트를 기준으로 만든 Windows 버전입니다.
Docker Desktop은 Linux containers 모드로 실행되어 있어야 합니다. 실제 설치·업데이트는 **관리자 PowerShell 7**에서 실행합니다.
이 폴더 전체를 함께 사용하세요 (`fe-common.psm1`, `nginx/nginx.conf` 포함).

## 실행

```powershell
cd C:\Users\rainbow\Desktop\Deploy\web-ui

# 읽기 전용: 기본 앱의 현재/원격 버전과 업데이트 정책 확인
.\fe-deploy.ps1 -Action Plan -Branch main

# 기본 앱(shell, assets, common) 설치 + observer 작업 등록/시작
.\fe-deploy.ps1 -Action Install -Branch main

# 추가 앱 포함 설치
.\fe-deploy.ps1 -Action Install -Branch main -Apps S100

# 현재 설치 앱 업데이트 / 특정 앱 추가
.\fe-update.ps1
.\fe-add-app.ps1 -Apps S100

# 자동 감시 없이 설치
.\fe-deploy.ps1 -Action Install -Branch main -SkipObserver

# 오프라인 총 패키지 ZIP 또는 추출된 폴더
.\fe-deploy.ps1 -Action Update -InputPath C:\Packages\web-ui.zip

# FO가 명시된 경우에만 Edge 키오스크 등록/시작
.\fe-deploy.ps1 -Action Install -Branch main -Apps S100 -FO /S100

# observer 관리 / 한 번 검사
.\fe-version-observer.ps1 -Action Install
.\fe-version-observer.ps1 -Action Status
.\fe-version-observer.ps1 -Action Once
.\fe-version-observer.ps1 -Action Uninstall
.\view-observer-log.ps1 -Follow

# 앱 제거: 기본은 컨테이너/해당 방화벽 규칙만 제거; 파일 보존
.\fe-delete-app.ps1 -Apps S100 -WhatIf
.\fe-delete-app.ps1 -Apps S100
.\fe-delete-app.ps1 -Apps S100 -RemoveFiles

# 키오스크 자동 실행 해제 (실행 중인 브라우저를 강제 종료하지 않음)
.\browser.ps1 -Action Uninstall
```

기본 경로:

| 대상 | 경로 |
|---|---|
| Web UI 설치 | `C:\ProgramData\Rainbow\WebUI` |
| 설정 | `WebUI\config\install.json` |
| 앱 파일/버전 | `WebUI\apps\<app>` |
| nginx 설정 | `WebUI\nginx\nginx.conf` |
| 로그 | `WebUI\logs\observer.log` (5 MB 회전) |
| observer 오프라인 ZIP 반입 | `C:\ProgramData\Rainbow\Muscat\data\deploy\web-ui\observe` |
| 상태 파일 | `C:\ProgramData\Rainbow\Muscat\data\deploy\web-ui-status.json` |

`-InstallRoot`, `-MuscatRoot`, `-UpdateInfoUrl`로 경로/API를 바꿀 수 있습니다. 사용자 지정 경로로 observer를 직접 등록할 때도 같은 값을 전달하세요.
기본 API는 `http://localhost:3000/common/deploy/update-info?category=web-ui`입니다.

## Linux 동작과 대응

- S3/CloudFront의 `web-rainbow-ui/<branch>/version.json`과 앱별 `<app>/<version>.zip`을 사용합니다.
- `services` 매니페스트와 레거시 앱별 `version.json`을 지원합니다. 신규 매니페스트는 observer가 받은 스냅샷을 배포기에 전달합니다.
- `hostinfo.json`의 포트를 그대로 사용합니다. 앱별 `ui-<app>` nginx 컨테이너, 공용 nginx 설정과 shared 디렉터리, Docker 로그 제한(10m/5)을 유지합니다.
- 정적 파일만 바뀌면 컨테이너를 유지합니다. 같은 버전은 다운로드하지 않습니다. 컨테이너의 포트/이미지 이름/마운트/로그 설정이 다르면 재생성하고, 설정이 같은 중지 컨테이너는 시작합니다. `nginx:alpine`을 매 주기 새 이미지로 갱신하지 않습니다.
- 새 파일을 준비하고 **모든 대상의 포트와 패키지를 검증한 뒤** 반영합니다. 다른 컨테이너나 Windows 프로세스가 포트를 사용하면 중단합니다. 특히 기존 Muscat이 8180/5174/5176/5177을 게시한 경우 Web UI와 충돌할 수 있습니다. 포트/기존 컨테이너/portproxy는 임의로 바꾸거나 제거하지 않습니다.
- 앱마다 `Rainbow-WebUI-<app>-TCP` 방화벽 규칙을 만듭니다. TCP, 해당 앱 포트, 모든 프로필과 원본 주소를 허용합니다. Linux의 `ufw allow <port>`에 대응합니다. Windows 방화벽 전체를 켜거나 끄지는 않습니다.
- 교체 전 파일을 백업합니다. nginx 설정 및 컨테이너 내부 HTTP 검사가 실패하면 해당 앱 파일을 복원합니다. 재생성은 기존 컨테이너를 중지/임시 이름으로 보관한 뒤 진행하여 실패 시 기존 컨테이너로 되돌립니다. 여러 앱 전체가 하나의 트랜잭션은 아니며, 앞서 성공한 앱은 유지합니다.
- 백업과 추출 파일은 `WebUI\staging`에 남깁니다. 필요 없는 과거 파일은 observer를 중지하고 삭제할 수 있습니다.
- 온라인 자동 업데이트는 `available=1`, `autoUpdate=1`이 모두 필요합니다. `main`은 변경되는 앱별 `hotfix=true`가 추가로 필요합니다. 같은 앱 버전은 `total`만 갱신합니다.
- 오프라인 ZIP은 먼저 처리합니다. 크기/수정 시각이 두 번의 검사에서 같고 5초 이상 안정된 파일만 처리합니다. 성공하면 반입 ZIP을 `packages\observed`로 옮기고 `autoUpdate=0`으로 설정합니다. 실패 ZIP은 남겨 재시도합니다.
- 설치된 Web UI가 있으면 오프라인 배포에도 `available=1`이 필요합니다. 미설치 상태에서 API가 없으면 오프라인 최초 설치를 허용합니다. 다만 배포 후 API에 자동 업데이트 비활성화 요청이 실패하면 실패 상태를 남기고 ZIP을 보존합니다.
- 공식 오프라인 ZIP은 `version.json` + `apps/<app>/hostinfo.json` 구조입니다. 패키지 브랜치를 적용합니다.
- `version.json`/`apps`가 없고 `shell/hostinfo.json`을 포함한 dist ZIP도 지원합니다. 실행 중인 앱만 교체하고 포트는 바꾸지 않습니다. 버전은 pinned 처리해 다음 정식 배포가 덮어쓸 수 있게 합니다.

## Windows 방식

- systemd 대신 현재 사용자의 로그인 시 실행되는 `Rainbow-WebUI-Observer` 작업을 등록합니다. 최고 권한/사용자 로그인 세션으로 실행하므로 Docker Desktop 사용자 컨텍스트를 사용합니다. Docker가 준비되지 않으면 다음 주기에 재시도합니다. 로그아웃 상태에서 실행되는 Windows 서비스는 아닙니다.
- 키오스크는 명시적인 `-FO` 옵션 또는 `browser.ps1 -Action Install`에서만 등록합니다. Windows Edge kiosk를 사용하고, shell의 실제 포트와 `rb_mode`를 적용합니다. Linux의 Firefox 창 강제 최상단 감시는 옮기지 않았습니다.
- Linux 패키지 관리자 설치, Docker 자동 설치, deploy-kit을 원격 상태로 강제 재설정하는 Git timer는 포함하지 않았습니다.
- Muscat/Zenoh listen endpoint, portproxy, 다른 앱 설정은 수정하지 않습니다.

## 검증 범위

PowerShell 문법 검사, 실제 main 매니페스트의 읽기 전용 Plan, 모의 Docker를 통한 버전 정책/파일 비교/컨테이너 유지·재생성/실패 복원/dist pin/ZIP 경로 검증을 수행했습니다.
관리자 권한이 필요한 방화벽·작업 스케줄러 등록과 실제 운영 앱 설치는 실행하지 않았습니다.
임시 nginx 컨테이너를 사용하는 실제 Docker 검사도 시도했으나 이 환경에서 `docker run`이 완료되지 않아 중단했습니다. 따라서 실제 nginx 구동/HTTP 검사까지 통과했다고 보증하지 않습니다. 테스트용 컨테이너는 남아 있지 않은지 확인했습니다.
