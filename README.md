# Codex Storage Guard

[한국어 문서](README.ko.md)

[![Cross-platform validation](https://github.com/dd3ok/codex-cleaner/actions/workflows/validate.yml/badge.svg)](https://github.com/dd3ok/codex-cleaner/actions/workflows/validate.yml)

Codex Storage Guard is the read-only core of the `codex-cleaner` personal skill. It measures `CODEX_HOME` as opaque filesystem data and combines that inventory with the supported top-level `codex doctor --json` result. It never parses private Codex databases or rollout formats and contains no cleanup primitive.

## Why it exists

A filesystem path, age, size, task title, archived flag, or CLI capability is not deletion authority. The guard gives Codex a repeatable inspection contract and prevents a storage observation from being promoted into an unsafe lifecycle operation.

It reports:

- apparent bytes for every immediate child of `CODEX_HOME`, without hardcoded area names;
- the largest files observed during traversal;
- skipped links, mounts, special files, races, and other coverage limitations;
- recognized `codex doctor --json` status;
- tri-state `archive`, `delete`, and `unarchive` command capability probes;
- an explicit policy that blocks archive and delete automation.

The inventory is live best-effort metadata, not an atomic snapshot, allocated-disk measurement, reclaimed-byte estimate, or system-wide inventory. Effective state roots outside `CODEX_HOME` are not traversed.

## Lifecycle boundary

Current stable `archive` and `delete` commands may also affect spawned descendants, while the stable command surface does not provide an affected-task preview that can be bound to the same operation. The skill therefore does not plan or run those commands. Exact root-task approval and user risk acceptance do not prove the complete impact set.

`unarchive` is reversible but is not storage cleanup. Use the official Codex task interface directly when it is explicitly requested.

The skill does not delete raw files, inspect private SQLite schemas, classify orphan assets, vacuum logs, kill processes, clean project caches, or manage plugins.

## Repository layout

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

## Requirements

- Windows, macOS, or Linux
- Codex Desktop or Codex CLI with personal skill support
- Python 3.10 or newer using only the standard library

## Installation

Clone the repository and copy only the installable skill directory into your personal skills directory:

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

The skill is available to a new Codex turn after installation.

## Usage

Ask Codex:

```text
Use $codex-cleaner to inspect my Codex storage without deleting anything.
```

Or run the read-only script directly:

```powershell
python -I -B .\codex-cleaner\scripts\codex_storage_guard.py
```

Use `--codex-home`, `--codex-executable`, or `--top` only when the defaults are not appropriate. Run `--help` for the current interface. The script emits one JSON assessment to standard output.

## Validation

```powershell
python -I -B .\codex-cleaner\scripts\test_codex_storage_guard.py
```

The regression suite uses temporary synthetic trees and fake Codex executables. GitHub Actions runs it on Windows, Ubuntu, and macOS. It must not modify live Codex data.
