# Codex Storage Guard

[English](README.md)

[![크로스플랫폼 검증](https://github.com/dd3ok/codex-cleaner/actions/workflows/validate.yml/badge.svg)](https://github.com/dd3ok/codex-cleaner/actions/workflows/validate.yml)

Codex Storage Guard는 `codex-cleaner` 개인 스킬에서 안전한 읽기 전용 핵심만 남긴 도구입니다. `CODEX_HOME`을 내부 형식을 모르는 파일시스템 데이터로 측정하고, 공식 최상위 `codex doctor --json` 결과와 결합합니다. 비공개 Codex 데이터베이스나 rollout 형식을 해석하지 않으며 정리 기능도 포함하지 않습니다.

## 존재 이유

경로, 날짜, 크기, task 제목, 보관 표시 또는 CLI 명령 지원 여부는 삭제 권한이 아닙니다. 이 스킬은 반복 가능한 저장공간 점검 계약을 제공하고, 관찰 결과가 근거 없는 lifecycle 작업으로 확대되는 것을 막습니다.

다음을 보고합니다.

- 영역 이름을 하드코딩하지 않고 측정한 `CODEX_HOME` 직속 항목별 apparent bytes
- 탐색 중 확인한 가장 큰 파일
- 건너뛴 링크·mount·특수 파일·경합과 그 밖의 coverage 제한
- 인식 가능한 `codex doctor --json` 상태
- `archive`, `delete`, `unarchive` 명령에 대한 3상태 capability probe
- archive와 delete 자동화를 차단하는 명시적 정책

결과는 실행 중 파일 메타데이터를 최선으로 관찰한 값입니다. 원자적 스냅샷, 실제 할당 디스크 용량, 회수 가능 용량 또는 시스템 전체 목록이 아닙니다. `CODEX_HOME` 밖에 설정된 실제 상태 루트는 탐색하지 않습니다.

## Task lifecycle 경계

현재 안정 버전의 `archive`와 `delete`는 선택한 task의 하위 spawned task에도 영향을 줄 수 있지만, 같은 작업에 결박할 수 있는 영향 task 전체 미리보기는 안정 인터페이스에 없습니다. 따라서 이 스킬은 두 명령의 계획을 만들거나 실행하지 않습니다. 루트 task를 정확히 승인하거나 사용자가 위험을 수락해도 전체 영향 집합이 증명되지는 않습니다.

`unarchive`는 되돌릴 수 있지만 저장공간 정리가 아닙니다. 명시적으로 요청한 경우 공식 Codex task 인터페이스를 직접 사용합니다.

이 스킬은 원시 파일 삭제, 비공개 SQLite 스키마 검사, orphan 자산 분류, 로그 vacuum, 프로세스 종료, 프로젝트 캐시 정리 또는 플러그인 관리를 하지 않습니다.

## 저장소 구조

```text
.
├── .github/workflows/validate.yml
├── README.md
├── README.ko.md
└── codex-cleaner/
    ├── SKILL.md
    ├── agents/openai.yaml
    └── scripts/
        ├── codex_storage_guard.py
        └── test_codex_storage_guard.py
```

## 요구 사항

- Windows, macOS 또는 Linux
- 개인 스킬을 지원하는 Codex Desktop 또는 Codex CLI
- 표준 라이브러리만 사용하는 Python 3.10 이상

## 설치

저장소를 복제한 다음 설치 가능한 스킬 디렉터리만 개인 스킬 경로에 복사합니다.

```powershell
git clone https://github.com/dd3ok/codex-cleaner.git
Set-Location .\codex-cleaner

$codexHome = if ($env:CODEX_HOME) {
  $env:CODEX_HOME
} else {
  Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
}
$skillParent = Join-Path $codexHome 'skills'
$destination = Join-Path $skillParent 'codex-cleaner'

if (Test-Path -LiteralPath $destination) {
  throw "A codex-cleaner skill already exists at $destination. Review it before replacing it."
}

New-Item -ItemType Directory -Path $skillParent -Force | Out-Null
Copy-Item -LiteralPath '.\codex-cleaner' -Destination $destination -Recurse
```

설치 후 다음 Codex turn부터 스킬을 사용할 수 있습니다.

## 사용법

Codex에 다음과 같이 요청합니다.

```text
$codex-cleaner로 Codex 저장공간을 읽기 전용으로 점검해줘.
```

읽기 전용 스크립트를 직접 실행할 수도 있습니다.

```powershell
python -I -B .\codex-cleaner\scripts\codex_storage_guard.py
```

기본값이 맞지 않을 때만 `--codex-home`, `--codex-executable`, `--top`을 사용합니다. 현재 인터페이스는 `--help`로 확인할 수 있습니다. 스크립트는 JSON assessment 하나를 표준 출력에 기록합니다.

## 검증

```powershell
python -I -B .\codex-cleaner\scripts\test_codex_storage_guard.py
```

회귀 테스트는 임시 합성 트리와 가짜 Codex 실행 파일만 사용합니다. GitHub Actions는 Windows, Ubuntu, macOS에서 실행하며 실제 Codex 데이터를 변경하지 않아야 합니다.
