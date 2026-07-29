# Cross-platform Codex storage and safety map

Use this map to interpret a read-only snapshot and design a separate, explicitly authorized action manifest on Windows, macOS, or Linux. Treat paths, schemas, and CLIs as versioned. Unknown means protect.

## Contents

- Supported platforms and roots
- User content and state
- Runtime and regenerable data
- Snapshot decision gate
- Task consistency and activity
- Cross-platform destructive-path preflight
- Platform-specific path rules
- Process preflight
- Action manifest and creation ledger
- SQLite log maintenance
- Image retention test
- Excess-report test

## Supported platforms and roots

Codex state uses `CODEX_HOME`, which defaults to `~/.codex` on Windows, macOS, and Linux. Do not assume the literal home-relative path when `CODEX_HOME` is set.

SQLite state may use `CODEX_SQLITE_HOME`, and the `sqlite_home` config option takes precedence. Resolve the effective state root before scanning. If it cannot be established exactly, protect every database- and task-dependent record.

Use PowerShell 7 and Python 3. The read-only snapshot reports its platform, path case behavior, and mount-inventory status. Do not permit review classification unless `Safety.PlatformPathSafetyComplete` is true.

## User content and state

| Path | Meaning | Default |
|---|---|---|
| effective state root `state_*.sqlite` | Task index, rollout path, archive state, and relationships | Read-only; never edit or compact |
| `$CODEX_HOME/sessions/**/*.jsonl` | Non-archived task rollouts | Protect unless the user selects the task |
| `$CODEX_HOME/archived_sessions/**/*.jsonl` | Archived task rollouts | Historical content; exact task selection required |
| `$CODEX_HOME/generated_images/<task-id>/` | Raw task image generations used by task UI | Separate exact authorization; never automatic |
| `$CODEX_HOME/visualizations/YYYY/MM/DD/<task-id>/` | Per-task visualization artifacts | Separate exact authorization; unexpected layouts are ambiguous |
| `$CODEX_HOME/attachments/` | Pasted or attached task inputs | Protect unless exact reference and authorization are proven |
| `$CODEX_HOME/skills/`, `.agents/skills/` | Personal and system skills | Always protect |
| `$CODEX_HOME/config*`, credentials, instructions | Behavior and access state | Always protect |

Task deletion and every asset deletion are distinct operations. A durable project copy can keep a project working but does not keep the raw image visible in its original Codex task.

## Runtime and regenerable data

| Path | Meaning | Handling |
|---|---|---|
| `$CODEX_HOME/logs_*.sqlite` | Structured app logs | Offline selected checkpoint/VACUUM only; never delete |
| `$CODEX_HOME/.tmp/` | Plugin and marketplace staging | Protect while Codex runs; prove inactivity and select exact paths |
| `$CODEX_HOME/plugins/` | Installed plugin runtime/cache | Protect while Codex runs; prove obsolete lifecycle before selection |
| OS app/runtime/cache roots | Installed app and regenerable runtime | Discover from the installed process and supported configuration; never guess |
| OS temporary root | Tool/browser/test environments | Require an exact path, inactivity, ownership, and no process reference |
| project `node_modules`, `build`, `.godot`, `.expo`, `dist` | Rebuildable project state | Selection required after ignored, untracked, inactive proof |

## Snapshot decision gate

The supplied snapshot is analysis-only and is never a delete list. The following conditions permit review classification only:

- the scan is complete with no critical read errors;
- the current task ID was supplied and its full parent/child connected family was protected;
- the authoritative state database had no WAL/SHM sidecars and was opened immutable/read-only;
- every rollout filename contains one canonical UUID and its first `session_meta` record contains the same ID;
- state task IDs and rollout IDs agree with no missing, stray, or duplicate IDs;
- expected image and visualization layouts were measured without ambiguity;
- child-root, database, rollout, and asset path chains contain no symbolic links, junctions, reparse points, or nested mounts;
- the platform mount inventory and case-aware containment checks completed;
- the read transaction and pre/post capture checks show no DB/WAL/SHM, rollout, graph, image, or visualization change during capture.

Even when all conditions pass, each record remains protected and review-only. A separately displayed action manifest and category-specific authorization are still required.

## Task consistency and activity

Read quiescent task state with SQLite URI `mode=ro&immutable=1` and `PRAGMA query_only=ON`. Compare state IDs and recorded rollout paths with both rollout trees. Compute activity conservatively as the latest available value among state update time, rollout metadata/content, and filesystem timestamps.

Do not open a state database when `-wal` or `-shm` exists. SQLite WAL readers can interact with the shared-memory index differently across platforms. Require an offline, quiescent database and use `mode=ro&immutable=1`; if a sidecar appears or any fingerprint changes during the read, discard the result and protect all dependent records.

Protect a task when any of these applies:

- it is current, recent, explicitly protected, or connected to a protected task by any parent/child edge;
- the database, rollout, path, ID, timestamp, or graph is missing or inconsistent;
- an asset directory uses an unexpected or nested task-ID layout;
- it is referenced by state or a rollout;
- its content classification is unknown.

Use the supported Codex task-management tool or verified installed CLI for selected task deletion. Never delete rollout files or database rows to imitate task deletion.

## Cross-platform destructive-path preflight

For each exact selected path:

1. Canonicalize the existing path and its intended parent.
2. Compare with a path-separator boundary using the host filesystem's case rules, not a raw string prefix.
3. Reject a filesystem root, user-profile root, Codex root, SQLite state root, repository/workspace root, skills, config, credentials, and instructions.
4. Inspect every ancestor from the filesystem root through the intended parent, target, and every traversed descendant. Reject symbolic links, junctions, reparse points, and nested or bind mounts.
5. Record path, file, filesystem/device, and mount identity where available, then resolve and repeat all checks immediately before mutation.
6. Use an exact literal path; never use a recursive wildcard, unresolved variable, or broad computed root.

For project caches, additionally require `git check-ignore` success, no tracked files below the target, no active process reference, and a stated rebuild cost.

## Platform-specific path rules

### Windows

- Compare canonical paths case-insensitively.
- Reject every reparse point, including junctions, symbolic links, and mount points.
- Reject alternate data streams and unexpected `\\?\`, NT device, or UNC namespaces.
- Revalidate the volume serial and file identity when available.

### macOS

- Compare paths case-sensitively unless the exact mounted filesystem is proven case-insensitive; default to the stricter case-sensitive comparison.
- Use `lstat`-equivalent metadata and the native mount table. Reject symbolic links and nested mounts.
- Protect APFS firmlinks, snapshots, external volumes, and synthetic paths when their traversal or identity is not fully understood.
- Reject device nodes and paths outside the selected filesystem boundary.

### Linux and WSL

- Compare paths case-sensitively.
- Use `lstat`-equivalent metadata and `/proc/self/mountinfo`. Reject symbolic links, nested mounts, bind mounts, overlay boundaries, and unexpected namespaces.
- Revalidate device/inode identity and the mount ID immediately before mutation.
- Treat container, network, FUSE, and WSL host-mounted paths as Protect unless the exact boundary and lifecycle are proven.

## Process preflight

Process cleanup is separate from file cleanup. Require an exact user-selected process record containing PID, creation/start time, executable path and identity, command line, parent/child tree, and listening ports. On Linux include `/proc/<pid>` start time and namespace/cgroup context when available. On macOS use native process metadata instead of PID alone. On Windows bind to creation time and executable identity. Immediately before signaling, re-query and compare the full tuple to the approved manifest; any mismatch or PID reuse invalidates approval. Re-query again before a force signal or termination. Protect system processes, Codex, the IDE, the current agent tree, and any process serving a live task. Attempt graceful shutdown first. Force needs separate explicit approval bound to the same identity.

## Action manifest and creation ledger

Never consume the diagnostic snapshot as an action manifest. Give each displayed mutation manifest a fresh ID, canonical snapshot digest, creation and expiry time, stable item IDs, exact categories and targets, and rollback consequence. Require a later reply that identifies the manifest and selected items. Invalidate it on expiry, rescan, scope or evidence change, process identity change, or relevant state change.

Create current-run residue only under a new GUID temporary directory. Verify each path was absent before creation and record its canonical path, file and filesystem identity when available, size, SHA-256, and creation time in memory. Never adopt, overwrite, or delete a pre-existing path. Before removal, revalidate the same identity, hash, containment, and link- and nested-mount-free path chain.

## SQLite log maintenance

Never modify `state_*.sqlite`. For an explicitly selected `logs_*.sqlite`:

1. Confirm Codex and every possible writer are closed.
2. Confirm free space is at least `2 × database size + 512 MB`.
3. Open through SQLite, set a short busy timeout, and run `PRAGMA quick_check`.
4. If busy or not `ok`, stop without mutation.
5. Use SQLite checkpoint/VACUUM operations; never delete `-wal` or `-shm`.
6. Run `PRAGMA quick_check` again and verify the application after restart.

Do not perform this maintenance from inside the running Codex desktop session.

## Image retention test

Hash raw images and search durable project asset/artifact directories. Record exact matches as “copy exists,” unmatched files as “possibly unique,” and search failures as “unknown.” None of these states authorizes automatic deletion. Require exact task-ID selection for raw image directories and always protect current-family assets.

Do not persist a hash manifest unless requested. Keep it in memory or an isolated temporary directory and remove it after verification.

## Excess-report test

Scan only explicitly selected project roots. Exclude VCS metadata, dependency trees, build outputs, environments, and reparse points. Names containing `report`, `audit`, `summary`, `handoff`, `contact-sheet`, or `cleanup` are review candidates only; substrings such as `reporting` are not sufficient.

Delete a report only when at least one applies:

- it was generated solely for the current cleanup and its result was already delivered;
- it is byte-identical to a durable copy;
- it is a reproducible generated output in an ignored directory;
- the user explicitly selects it.

Default to one response summary and zero report files.
