---
name: codex-cleaner
description: Inspect Codex desktop and CLI storage without parsing private formats, and explain which cleanup requests cannot yet be automated safely. Use when Codex storage is growing, the user wants a storage audit, or old task archive/deletion safety must be assessed. Do not use for project caches, raw Codex files, databases, plugins, or process cleanup.
---

# Codex Storage Guard

Measure Codex storage as opaque filesystem data. Optionally add the supported top-level `codex doctor --json` result when the user also requests installation or health diagnostics. Never turn an observation into deletion authority.

The read-only script is `scripts/codex_storage_guard.py`, relative to this file. Run `python <script> --help` for its current interface. Do not search the user's project for another copy.

## Safety contract

- Treat inspect, audit, diagnose, candidate, archive, and delete requests as read-only until the affected task set can be proven.
- Treat unknown, unreadable, changing, or unsupported observations as **Protect** for any filesystem-derived decision.
- Never interpret or directly change Codex SQLite databases, rollout files, generated images, visualizations, attachments, caches, config, credentials, skills, plugins, or process state.
- Never use a path, filename, age, size, task title, or model judgment as deletion authority.
- Never claim an atomic snapshot, complete system-wide coverage, allocated disk usage, reclaimed bytes, or target-state verification.
- Treat official CLI discovery, doctor, and capability probes as advisory adapters. Preserve the opaque inventory when an adapter is unavailable or unrecognized.
- Do not create reports, plans, manifests, receipts, or retention schedulers by default.

## Inspect

Run the script once without `--doctor`. It dynamically measures every immediate child of `CODEX_HOME`, skips links and nested mounts when observed, and does not hardcode Codex storage area names. Standard-library traversal is not race-free; report that limitation instead of claiming a link-proof snapshot.

Add `--doctor` only when the user also requests Codex installation or health diagnostics. State that doctor is a broader redacted diagnostic that may perform network and provider reachability checks.

Summarize:

- total apparent bytes and the largest opaque areas;
- `coverage.completeWithinRoot` and every limitation;
- that coverage is limited to `CODEX_HOME`; config `sqlite_home` takes precedence over `CODEX_SQLITE_HOME`, and `log_dir` may also be external;
- doctor status/schema recognition when requested and tri-state official task capability probes; treat `unknown` as unknown, not unsupported;
- that no returned record authorizes a lifecycle operation or raw-file deletion.

The capability list reports what the installed CLI exposes, not what this guard considers safe to automate.

## Handle task lifecycle requests

`archive` and `delete` may apply to the selected root task and spawned descendants. The current stable command surface does not provide an affected-task preview that can be bound to a conditional operation. Exact root UUID approval therefore does not prove the complete impact set.

For `archive` or `delete`:

- do not create a plan or run the command through this skill;
- explain the affected-set blocker and that user risk acceptance is not state proof;
- do not suggest protected UUIDs as an effective safeguard;
- re-evaluate only when an official stable interface can return the complete affected UUID set and conditionally apply that same set.

`unarchive` is a storage mutation, not cleanup. Keep it outside this skill and do not run it. If the user asks separately, explain that command availability and reversibility do not prove concurrency safety; use only an official Codex task interface after its installed version and active-writer safety are independently established.

## Boundaries

This skill deliberately does not classify orphan assets, reconstruct task graphs from private storage, vacuum logs, kill workers, clean project caches, manage plugins, or delete raw files. Those jobs have separate ownership and risk models; do not grow this skill to absorb them.
