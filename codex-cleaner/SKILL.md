---
name: codex-cleaner
description: Audit and safely reduce accumulated Codex desktop and CLI data on Windows, including old or archived tasks, rollout files, generated images, orphan visualizations, oversized SQLite logs, stale temp data, regenerable project caches, migration backups, and excessive cleanup reports. Use when Codex storage keeps growing, old conversations or image generations need classification, memory is held by duplicate or stale worker processes, a migration left residue, or the user asks to inspect, clean, compact, or establish retention rules for Codex data.
---

# Codex Cleaner

Audit and reduce Codex storage without breaking current tasks, task families, projects, skills, settings, or unique generated assets. The supplied snapshot is permanently read-only and fail-closed. Every reported record is evidence for review, never permission to delete it.

## Safety contract

- Treat “check”, “analyze”, “diagnose”, and “show candidates” as read-only requests.
- Treat unknown, unreadable, inconsistent, busy, or ambiguous state as **Protect**.
- Keep analysis and mutation in separate phases. Never place destructive primitives in the snapshot tool.
- Require the exact current task ID. Protect its entire connected parent/child task family. If the ID or graph cannot be established, do not classify task assets for deletion review.
- Never infer chained authorization. Deleting a task does not authorize deleting its images, visualizations, attachments, project copies, logs, or caches.
- Never delete global instructions, configuration, authentication, `.codex/skills`, `.agents/skills`, the Codex root, or a current task family.
- Never edit or delete project source merely because it is old. Protect tracked files, untracked work, and repositories with changes.
- Treat raw generated images as UI task assets. Deleting their task directory can remove images from the Codex task even when a project copy exists.
- Treat a matching project image as evidence of a copy, not automatic deletion permission. Protect unmatched and ambiguous images.
- Never edit `state_*.sqlite`. Never delete a SQLite database, `-wal`, or `-shm` file directly.
- On Windows, validate the exact absolute target and its containment, inspect ancestors, target, and traversed descendants for reparse points, revalidate immediately before mutation, and operate on exact paths only.
- Never use broad globs, environment-variable-expanded roots, home directories, or workspace roots as recursive deletion targets.
- Do not create a report by default. Summarize in the response. Create one report only when explicitly requested, at an explicit path, and remove temporary audit artifacts.

Read [references/windows-storage-map.md](references/windows-storage-map.md) before interpreting Codex internals or planning any mutation.

## 1. Establish scope

Identify the Codex root, exact current task ID, connected task family, project roots, protected projects, active processes, and the precise action the user authorized. “Do it without asking” changes interaction style, not deletion scope.

Run the read-only snapshot:

```powershell
$codexHome = if ($env:CODEX_HOME) {
  $env:CODEX_HOME
} else {
  Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
}
$skillRoot = (Resolve-Path -LiteralPath (Join-Path $codexHome 'skills\codex-cleaner')).Path
$snapshotScript = Join-Path $skillRoot 'scripts\Get-CodexStorageSnapshot.ps1'
pwsh -NoProfile -File $snapshotScript `
  -CurrentTaskId "<current-task-uuid>" -AsJson
```

Resolve the skill path from the loaded `SKILL.md`; never search the current project for a same-named script. Pass project roots only when report review is useful:

```powershell
pwsh -NoProfile -File $snapshotScript `
  -CurrentTaskId "<current-task-uuid>" `
  -ProjectRoot "C:\path\to\project" -AsJson
```

The snapshot must not delete, move, stop, compact, quarantine, or modify anything. It may report historical review records only when:

- `ScanComplete` is true;
- top-level `ReviewClassificationComplete` is true;
- `Safety.TaskConsistencyValid` is true;
- `Safety.AuthoritativeStateDatabaseResolved` is true;
- `Safety.CaptureStable` is true;
- `Safety.CurrentTaskProtectionProvided` is true;
- `Errors` is empty.

If any gate is false, use measurements for diagnosis only and protect all uncertain targets.

## 2. Classify without deleting

Measure exact paths, file counts, bytes, last activity, references, and evidence. Use these classes:

1. **Protect** — current task family, recent or referenced task assets, unique or ambiguous images, project work, skills, config, active runtimes, and unreadable/inconsistent paths.
2. **Current-run residue** — files created under a fresh GUID-named temporary directory whose paths and identities were recorded in an in-memory ledger at creation. Require every path to have been absent before creation; never overwrite or adopt a pre-existing path. Record canonical path, file identity when available, size, SHA-256, and creation time. Before removal, require the same identity, hash, containment, and no reparse point. These are the only items a generic “clean safe residue” request may authorize. Never infer this class from a filename, date, location, or similarity.
3. **Regenerable, selection required** — ignored and untracked build output, dependency folders, downloadable QA tools, inactive profiles, and proven caches. Explain rebuild cost.
4. **Historical content, selection required** — old or archived tasks, rollouts, raw image histories, visualizations, attachments, logs, reports, migration archives, and prior release evidence.

Do not call classes 3 or 4 “safe.” A filename, age, archived flag, missing project path, duplicate hash, or snapshot record is not enough by itself.

## 3. Build an exact action manifest

Before any class 3 or 4 mutation, show an exact manifest containing:

- a fresh `ManifestId`, canonical snapshot SHA-256, `CreatedAtUtc`, and short `ExpiresAtUtc`;
- stable item IDs, exact paths or task IDs, category, bytes, evidence, and rollback or regeneration consequence;
- the current process identity tuple for any process action.

Require a later user reply that cites the `ManifestId` and exact item IDs or categories. A prior generic request such as “정리해줘”, “안전한 건 지워줘”, or “묻지 말고” is not selection. Expiry, any rescan, scope or evidence change, process identity change, or relevant filesystem/state change invalidates the manifest; never silently substitute items. Internal-only manifests are permitted solely for current-run residue already present in the creation ledger.

Never pipe snapshot paths into a destructive command and never treat the snapshot schema as an action manifest. Build a separate manifest only after the snapshot gates pass, then apply the selection rule above.

Additional gates:

- **Tasks:** require exact task IDs and a cutoff if age-based. Use the supported task API/tool or installed CLI. Never emulate deletion by editing the state database.
- **Images/visualizations/attachments:** authorize separately by exact task ID. Preserve raw directories for protected tasks. Hash matches only prove that another copy exists.
- **Project caches:** require containment below the selected repository, no reparse point, `git check-ignore` success, zero tracked files, and zero active process references.
- **Processes:** require separate explicit authorization and an exact PID record with creation time, executable path, command line, parent/child tree, and listening ports. Immediately before signaling, re-query and require the entire tuple to match the approved manifest; treat any mismatch or PID reuse as Protect and never substitute another process. Re-query again before any force termination, which needs separate approval bound to the same identity. Never stop the current Codex/IDE/system process tree. Prefer graceful shutdown.
- **SQLite logs:** require Codex and every writer to be closed, an explicit database selection, free space of at least twice the database size plus 512 MB, and `PRAGMA quick_check` before and after. Skip if busy. Never compact state databases.
- **Plugin/runtime/temp caches:** do not mutate them while Codex is running. Version-looking or old-looking directories are still protected until their lifecycle and inactivity are proven.

Immediately before deleting or moving a path, resolve and revalidate it from the volume root through every ancestor, target, and traversed descendant. Reject volume roots, the user profile root, the Codex root, repository/workspace roots, protected skill/config trees, containment failures, alternate data streams, unexpected device/UNC namespaces, and any reparse point in the relevant path tree.

## 4. Execute in increasing-risk order

Proceed only within the frozen manifest and authorization:

1. Remove exact current-run residue.
2. Remove exact selected regenerable data.
3. Stop exact selected stale processes, if separately authorized.
4. Delete exact selected tasks through a supported interface.
5. Handle exact selected task asset directories as separate operations.
6. Compact an exact selected log database only during a confirmed offline maintenance window.

If evidence changes between analysis and execution, stop and reclassify. Do not broaden the manifest during execution.

## 5. Verify

Repeat the read-only snapshot and verify:

- Every selected target is absent and every protected target remains.
- Task rows, rollout paths, task graph edges, and protected task-family assets remain consistent.
- Generated-image, visualization, and attachment directories are either referenced, explicitly preserved, or separately authorized and verified.
- Git status differs only where the user already had changes.
- Protected processes and services still run on their intended ports.
- Reclaimed bytes use before/after measurements; report estimates as estimates.
- No unneeded current-run creation-ledger artifacts remain. Preserve all pre-existing reports, contact sheets, temporary scripts, and backup copies unless they were separately exact-selected through a valid manifest.

## Response format

Lead with the result: changed or read-only, exact reclaimed space, affected processes, protected data, failed safety gates, and deferred selections. Do not write a separate report unless requested.
