# Codex Cleaner

[English](README.md)

[![크로스플랫폼 검증](https://github.com/dd3ok/codex-cleaner/actions/workflows/validate.yml/badge.svg)](https://github.com/dd3ok/codex-cleaner/actions/workflows/validate.yml)

Codex Cleaner는 Codex Desktop 및 CLI에 누적된 데이터를 분석하고 정리하기 위한 크로스플랫폼 개인 스킬입니다. Windows, macOS, Linux 및 WSL을 지원하며 현재 작업, 프로젝트, 스킬, 설정, 유일한 생성 이미지를 조용히 손상시키지 않는 것을 최우선으로 합니다.

포함된 스냅샷 도구는 영구적으로 읽기 전용이며, 불확실하면 작업을 중단하는 실패-폐쇄 방식으로 동작합니다. 스냅샷에 표시된 항목은 검토용 근거일 뿐 삭제 권한이 아닙니다.

## 점검할 수 있는 항목

- 활성·보관·누락·중복·불일치 상태의 task rollout
- task에 연결된 생성 이미지, 시각화 및 첨부파일
- Codex 상태 및 로그 SQLite 데이터베이스
- 임시 데이터, 플러그인·런타임 데이터 및 이관 백업
- 다시 생성할 수 있는 프로젝트 캐시와 빌드 결과물
- 과도하게 만들어진 정리 보고서와 감사 파일
- 메모리를 점유할 수 있는 중복 또는 잔류 작업자 프로세스
- OS별 symbolic link, junction, mount point, bind mount 및 경로 경계

## 안전 모델

Codex Cleaner는 분석과 변경을 분리합니다.

1. 정확한 Codex 루트, 현재 task ID, 연결된 task 계열, 프로젝트 경로 및 활성 프로세스를 확정합니다.
2. 읽기 전용 진단 스냅샷을 생성합니다.
3. 상태가 사용 중이거나 모호하고, 일관되지 않거나, 읽을 수 없거나, 캡처 중 변경되면 중단합니다.
4. 발견 항목을 `보호`, `이번 실행의 찌꺼기`, `재생성 가능·선택 필요`, `과거 콘텐츠·선택 필요`로 분류합니다.
5. 변경 후보에는 별도의 짧은 유효기간을 가진 action manifest를 만듭니다.
6. 사용자가 정확한 manifest와 항목을 다시 선택해야 합니다.
7. 실행 직전에 경로, 프로세스 identity 및 Codex 상태를 다시 검증합니다.
8. 작업 후 읽기 전용 스냅샷을 다시 실행하고 실제 회수 용량을 측정합니다.

오래된 날짜, 보관 표시, 파일명, 사라진 프로젝트 경로 또는 동일한 해시는 그 자체로 삭제 승인이 되지 않습니다.

## 항상 보호하는 항목

- 현재 task와 연결된 모든 부모·자식 task
- 전역 지침, 설정, 인증, `.codex/skills`, `.agents/skills`
- `CODEX_HOME`, 실제 SQLite 상태 루트 및 확인되지 않은 OS별 앱 데이터
- 프로젝트 소스, 추적 파일, 미추적 작업물 및 변경사항이 있는 저장소
- 유일하거나 일치본이 없고, 모호하거나, 현재 task에 속한 생성 자산
- `state_*.sqlite` 및 SQLite `-wal`·`-shm` 파일
- Codex, IDE, 시스템 및 현재 에이전트 프로세스
- identity, 포함 관계, 소유자 또는 비활성 상태를 증명할 수 없는 경로

## 저장소 구조

```text
.
├── .github/workflows/validate.yml
├── README.md
├── README.ko.md
└── codex-cleaner/
    ├── SKILL.md
    ├── agents/
    │   └── openai.yaml
    ├── references/
    │   └── platform-storage-map.md
    └── scripts/
        ├── Get-CodexStorageSnapshot.ps1
        ├── read_codex_state.py
        └── test_codex_storage_snapshot.py
```

README는 설치할 스킬 폴더 밖에 있으므로 Codex의 스킬 컨텍스트에 불필요하게 로드되지 않습니다.

## 지원 플랫폼

| 플랫폼 | 경로 안전 검사 |
|---|---|
| Windows | 대소문자를 구분하지 않는 포함 관계 검사와 junction, symbolic link, reparse point, ADS, device, UNC 보호 |
| macOS | 보수적인 대소문자 구분과 symbolic link 및 네이티브 mount table 보호 |
| Linux / WSL | 대소문자 구분과 symbolic link, `/proc/self/mountinfo`, nested mount, bind mount 보호 |

운영체제 또는 mount 목록을 확정할 수 없으면 스냅샷은 실패-폐쇄 방식으로 분류를 중단합니다.

## 요구 사항

- Windows, macOS 또는 Linux
- 개인 스킬을 지원하는 Codex Desktop 또는 Codex CLI
- PowerShell 7 (`pwsh`)
- 표준 라이브러리만 사용하는 Python 3.10 이상

## 설치

저장소를 복제합니다.

```powershell
git clone https://github.com/dd3ok/codex-cleaner.git
Set-Location .\codex-cleaner
```

개인 Codex 스킬로 설치합니다.

```powershell
$codexHome = if ($env:CODEX_HOME) {
  $env:CODEX_HOME
} else {
  Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
}
$skillParent = Join-Path $codexHome 'skills'
$destination = Join-Path $skillParent 'codex-cleaner'

if (Test-Path -LiteralPath $destination) {
  throw "A codex-cleaner skill already exists at $destination. Review and merge it manually."
}

New-Item -ItemType Directory -Path $skillParent -Force | Out-Null
Copy-Item -LiteralPath '.\codex-cleaner' -Destination $destination -Recurse
```

Codex를 재시작하면 새 스킬을 인식합니다.

Codex는 기본적으로 `~/.codex`인 `CODEX_HOME`을 사용합니다. SQLite 상태는 `CODEX_SQLITE_HOME`으로 옮길 수 있으며 `sqlite_home` 설정이 우선합니다. 공식 [Codex 환경 변수 문서](https://learn.chatgpt.com/docs/config-file/environment-variables)를 참고하세요.

## 사용법

Codex에 스킬 사용을 요청합니다.

```text
$codex-cleaner로 현재 Codex 용량을 분석해줘. 아직 아무것도 삭제하지 마.
```

```text
$codex-cleaner로 오래된 대화, 생성 이미지와 프로젝트 캐시를 분류해줘.
정확한 action manifest만 보여주고 아직 삭제하지 마.
```

```text
$codex-cleaner로 메모리를 점유하는 잔류 Codex 프로세스를 점검해줘.
별도의 정확한 승인 없이는 프로세스를 종료하지 마.
```

task 자산을 삭제 검토 대상으로 분류하려면 정확한 현재 task UUID가 필요합니다. 현재 ID나 연결된 task 그래프를 확정할 수 없으면 관련 자산을 보호합니다.

## 읽기 전용 스냅샷

포함된 스크립트를 직접 실행할 수도 있습니다.

```powershell
$skillRoot = (Resolve-Path -LiteralPath '.\codex-cleaner').Path
$snapshotScript = Join-Path $skillRoot 'scripts\Get-CodexStorageSnapshot.ps1'

pwsh -NoProfile -File $snapshotScript `
  -CurrentTaskId '<current-task-uuid>' `
  -AsJson
```

SQLite 상태가 `CODEX_HOME` 밖에 있다면 실제 위치를 명시합니다.

```powershell
pwsh -NoProfile -File $snapshotScript `
  -CurrentTaskId '<current-task-uuid>' `
  -StateRoot '<effective-sqlite-state-root>' `
  -AsJson
```

다음 안전 게이트를 모두 통과해야 검토용 분류가 허용됩니다.

- `ScanComplete`
- `ReviewClassificationComplete`
- `Safety.TaskConsistencyValid`
- `Safety.AuthoritativeStateDatabaseResolved`
- `Safety.PlatformPathSafetyComplete`
- `Safety.CaptureStable`
- `Safety.CurrentTaskProtectionProvided`
- 비어 있는 `Errors`

모든 게이트를 통과해도 `UsableAsActionManifest`와 `RecordsAuthorizeDeletion`은 계속 `false`입니다.

## 검증

격리 회귀 테스트를 실행합니다.

```powershell
python -I -B .\codex-cleaner\scripts\test_codex_storage_snapshot.py
```

테스트는 임시로 만든 합성 Codex 트리만 사용합니다. 상태·rollout 일관성, 별도 SQLite 상태 루트, 실제 파일을 변경하지 않는 활성 WAL 거부, 중복·누락 기록, 생성 자산의 모호성, 현재 task 그래프 보호, symbolic link 또는 Windows junction 및 복수 상태 데이터베이스를 검사합니다. GitHub Actions가 Windows, Ubuntu 및 macOS에서 실행하며 실제 Codex 데이터는 변경하지 않아야 합니다.

## 중요한 제한 사항

- 이 프로젝트는 안전한 점검 절차와 진단 도구이며 한 번에 모두 지우는 삭제기가 아닙니다.
- 스냅샷에는 삭제나 프로세스 종료 기능이 들어 있지 않습니다.
- 과거 콘텐츠와 재생성 가능한 데이터는 항상 정확한 후속 선택이 필요합니다.
- task 삭제는 상태 DB를 직접 편집하지 않고 지원되는 Codex 인터페이스를 사용해야 합니다.
- WAL/SHM sidecar가 있으면 Codex가 완전히 종료된 안정 상태에서만 상태 DB를 검사합니다.
- SQLite 로그 최적화는 Codex가 완전히 종료된 오프라인 환경에서만 허용하며 상태 DB는 절대 최적화하지 않습니다.
- 백그라운드 상주 또는 정기 자동 정리를 자동으로 만들지 않습니다.
- OS별 앱 캐시 경로는 추측하지 않고 설치된 프로세스와 지원되는 설정에서 확인합니다.
- Codex 저장소 구조, mount 동작과 지원 인터페이스는 변경될 수 있으며 알 수 없는 구조는 보호합니다.

재현 가능한 Windows, macOS, Linux 및 WSL 예외 사례와 개선안은 GitHub issue 및 pull request로 환영합니다.
