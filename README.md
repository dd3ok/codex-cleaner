# Codex Cleaner

[한국어 문서](README.ko.md)

Codex Cleaner is a Windows-first Codex skill for auditing and reducing accumulated Codex Desktop and CLI data without silently breaking current tasks, projects, skills, settings, or unique generated assets.

Its bundled snapshot is permanently read-only and fail-closed. A snapshot record is evidence for review, never permission to delete data.

## What it audits

- Active, archived, missing, duplicate, and inconsistent task rollouts
- Generated images, visualizations, and attachments associated with tasks
- Codex state and log SQLite databases
- Temporary, plugin, runtime, and migration data
- Regenerable project caches and build output
- Excess cleanup reports and audit artifacts
- Duplicate or stale worker processes that may retain memory

## Safety model

Codex Cleaner separates analysis from mutation:

1. Establish the exact Codex root, current task ID, connected task family, project roots, and active processes.
2. Produce a read-only diagnostic snapshot.
3. Fail closed if state is busy, ambiguous, inconsistent, unreadable, or changes during capture.
4. Classify findings as `Protect`, `Current-run residue`, `Regenerable, selection required`, or `Historical content, selection required`.
5. Build a separate, short-lived action manifest for any proposed mutation.
6. Require the user to select the exact manifest and items.
7. Revalidate paths, process identities, and state immediately before acting.
8. Run another read-only snapshot and report measured reclaimed space.

The skill never treats age, an archived flag, a filename, a missing project path, or a matching hash as deletion authorization.

## Always protected

- The current task and its connected parent/child task family
- Global instructions, configuration, authentication, `.codex/skills`, and `.agents/skills`
- Project source, tracked files, untracked work, and repositories with changes
- Unique, unmatched, ambiguous, or current-task generated assets
- `state_*.sqlite` and SQLite `-wal`/`-shm` files
- Codex, IDE, system, and current-agent processes
- Any path whose identity, containment, ownership, or activity cannot be proven

## Repository layout

```text
.
├── README.md
├── README.ko.md
└── codex-cleaner/
    ├── SKILL.md
    ├── agents/
    │   └── openai.yaml
    ├── references/
    │   └── windows-storage-map.md
    └── scripts/
        ├── Get-CodexStorageSnapshot.ps1
        ├── read_codex_state.py
        └── test_codex_storage_snapshot.py
```

The README files stay outside the installable skill so they are not loaded into the Codex skill context.

## Requirements

- Windows 10 or 11
- Codex Desktop or Codex CLI with personal skill support
- PowerShell 7 (`pwsh`)
- Python 3 using only the standard library

## Installation

Clone the repository:

```powershell
git clone https://github.com/dd3ok/codex-cleaner.git
Set-Location .\codex-cleaner
```

Install it as a personal Codex skill:

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

Restart Codex so the new skill is discovered.

## Usage

Ask Codex to use the skill:

```text
Use $codex-cleaner to audit my Codex storage without deleting anything.
```

```text
Use $codex-cleaner to classify old tasks, generated images, and project caches.
Show an exact action manifest, but do not delete anything yet.
```

```text
Use $codex-cleaner to check whether stale Codex worker processes are retaining memory.
Do not stop any process without a separate exact authorization.
```

An exact current task UUID is required before task assets can be classified for deletion review. If it or the connected task graph cannot be established, the skill protects those assets.

## Read-only snapshot

The bundled script can also be run directly:

```powershell
$skillRoot = (Resolve-Path -LiteralPath '.\codex-cleaner').Path
$snapshotScript = Join-Path $skillRoot 'scripts\Get-CodexStorageSnapshot.ps1'

pwsh -NoProfile -File $snapshotScript `
  -CurrentTaskId '<current-task-uuid>' `
  -AsJson
```

The snapshot permits review classification only when all safety gates pass:

- `ScanComplete`
- `ReviewClassificationComplete`
- `Safety.TaskConsistencyValid`
- `Safety.AuthoritativeStateDatabaseResolved`
- `Safety.CaptureStable`
- `Safety.CurrentTaskProtectionProvided`
- an empty `Errors` collection

Even then, `UsableAsActionManifest` and `RecordsAuthorizeDeletion` remain `false`.

## Validation

Run the isolated regression suite:

```powershell
python -I -B .\codex-cleaner\scripts\test_codex_storage_snapshot.py
```

The suite uses synthetic temporary Codex trees. It covers state/rollout consistency, active SQLite WAL handling, duplicate and missing records, generated-asset ambiguity, current-task graph protection, reparse points, parent junctions, and multiple state databases. It must not modify live Codex data.

## Important limitations

- This is a safety workflow and diagnostic tool, not a one-command bulk deleter.
- The snapshot itself contains no destructive primitives.
- Historical content and regenerable data always require an exact later selection.
- Task deletion must use a supported Codex task interface, not direct state-database edits.
- SQLite log maintenance is allowed only during a confirmed offline window; state databases are never compacted.
- The skill does not run in the background or create scheduled cleanup automatically.
- Codex storage schemas and supported management interfaces may change; unknown layouts are protected.

Contributions and reproducible Windows edge cases are welcome through GitHub issues and pull requests.
