#!/usr/bin/env python3
"""Isolated regression tests for the read-only Codex storage snapshot."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time


PARENT_ID = "11111111-1111-4111-8111-111111111111"
CHILD_ID = "22222222-2222-4222-8222-222222222222"
ORPHAN_ID = "33333333-3333-4333-8333-333333333333"
NESTED_ID = "44444444-4444-4444-8444-444444444444"
STRAY_ID = "55555555-5555-4555-8555-555555555555"
GRANDCHILD_ID = "66666666-6666-4666-8666-666666666666"
SIBLING_ID = "77777777-7777-4777-8777-777777777777"


def write_rollout(path: Path, task_id: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {"type": "session_meta", "payload": {"id": task_id}}
    path.write_text(json.dumps(record) + "\n", encoding="utf-8")


def tree_manifest(root: Path) -> dict[str, tuple[int, int, str]]:
    result: dict[str, tuple[int, int, str]] = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        stat = path.stat()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        result[str(path.relative_to(root))] = (stat.st_size, stat.st_mtime_ns, digest)
    return result


def selected_file_manifest(paths: list[Path]) -> dict[str, tuple[int, int, str]]:
    result: dict[str, tuple[int, int, str]] = {}
    for path in paths:
        stat = path.stat()
        result[str(path)] = (
            stat.st_size,
            stat.st_mtime_ns,
            hashlib.sha256(path.read_bytes()).hexdigest(),
        )
    return result


def make_old(root: Path) -> None:
    old = time.time() - 30 * 24 * 60 * 60
    paths = sorted(root.rglob("*"), key=lambda item: len(item.parts), reverse=True)
    for path in paths + [root]:
        os.utime(path, (old, old))


def run_snapshot(
    script: Path,
    codex_root: Path,
    project_root: Path | None = None,
    protected: str | None = PARENT_ID,
    top: int | None = None,
) -> dict:
    command = [
        "pwsh",
        "-NoProfile",
        "-File",
        str(script),
        "-CodexRoot",
        str(codex_root),
        "-AsJson",
    ]
    if protected is not None:
        command.extend(["-CurrentTaskId", protected])
    if project_root is not None:
        command.extend(["-ProjectRoot", str(project_root)])
    if top is not None:
        command.extend(["-Top", str(top)])
    completed = subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return json.loads(completed.stdout)


def main() -> int:
    script = Path(__file__).with_name("Get-CodexStorageSnapshot.ps1").resolve()
    skill_root = script.parent.parent
    skill_text = (skill_root / "SKILL.md").read_text(encoding="utf-8")
    safety_phrases = [
        "ManifestId",
        "ExpiresAtUtc",
        "canonical snapshot SHA-256",
        "PID reuse",
        "volume root through every ancestor",
        "never overwrite or adopt a pre-existing path",
        "No unneeded current-run creation-ledger artifacts remain",
    ]
    for phrase in safety_phrases:
        assert phrase in skill_text, f"missing safety contract phrase: {phrase}"

    with tempfile.TemporaryDirectory(prefix="codex-cleaner-test-") as temp_name:
        temp_root = Path(temp_name)
        codex_root = temp_root / ".codex"
        project_root = temp_root / "project"
        session_root = codex_root / "sessions" / "2026" / "01" / "01"
        archive_root = codex_root / "archived_sessions"
        image_root = codex_root / "generated_images"
        visual_root = codex_root / "visualizations"
        archive_root.mkdir(parents=True)

        parent_rollout = session_root / (
            f"rollout-2026-01-01T00-00-00-{PARENT_ID}.jsonl"
        )
        child_rollout = session_root / (
            f"rollout-2026-01-01T00-00-01-{CHILD_ID}.jsonl"
        )
        grandchild_rollout = session_root / (
            f"rollout-2026-01-01T00-00-02-{GRANDCHILD_ID}.jsonl"
        )
        sibling_rollout = session_root / (
            f"rollout-2026-01-01T00-00-03-{SIBLING_ID}.jsonl"
        )
        write_rollout(parent_rollout, PARENT_ID)
        write_rollout(child_rollout, CHILD_ID)
        write_rollout(grandchild_rollout, GRANDCHILD_ID)
        write_rollout(sibling_rollout, SIBLING_ID)

        for task_id in (PARENT_ID, ORPHAN_ID):
            target = image_root / task_id
            target.mkdir(parents=True)
            (target / "image.png").write_bytes(task_id.encode("ascii"))
        for task_id in (CHILD_ID, ORPHAN_ID):
            target = visual_root / "2026" / "01" / "01" / task_id
            target.mkdir(parents=True)
            (target / "visual.json").write_text(task_id, encoding="utf-8")

        project_root.mkdir()
        (project_root / "cleanup-report.md").write_text("candidate", encoding="utf-8")
        (project_root / "audit-summary.md").write_text("candidate two", encoding="utf-8")
        (project_root / "handoff.txt").write_text("candidate three", encoding="utf-8")
        (project_root / "reporting.md").write_text("not a candidate", encoding="utf-8")
        (project_root / ".git").mkdir()
        (project_root / ".git" / "audit.md").write_text("excluded", encoding="utf-8")
        (project_root / "node_modules").mkdir()
        (project_root / "node_modules" / "summary.md").write_text(
            "excluded", encoding="utf-8"
        )

        database = codex_root / "state_1.sqlite"
        connection = sqlite3.connect(database)
        connection.executescript(
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                archived INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE thread_spawn_edges (
                parent_thread_id TEXT NOT NULL,
                child_thread_id TEXT NOT NULL
            );
            """
        )
        old_timestamp = int(time.time()) - 30 * 24 * 60 * 60
        connection.executemany(
            "INSERT INTO threads VALUES (?, ?, ?, ?)",
            [
                (PARENT_ID, str(parent_rollout.resolve()), 0, old_timestamp),
                (CHILD_ID, str(child_rollout.resolve()), 0, old_timestamp),
                (
                    GRANDCHILD_ID,
                    str(grandchild_rollout.resolve()),
                    0,
                    old_timestamp,
                ),
                (SIBLING_ID, str(sibling_rollout.resolve()), 0, old_timestamp),
            ],
        )
        connection.executemany(
            "INSERT INTO thread_spawn_edges VALUES (?, ?)",
            [
                (PARENT_ID, CHILD_ID),
                (CHILD_ID, GRANDCHILD_ID),
                (PARENT_ID, SIBLING_ID),
            ],
        )
        connection.commit()
        connection.close()
        make_old(codex_root)

        before = tree_manifest(temp_root)
        baseline = run_snapshot(script, codex_root, project_root)
        after = tree_manifest(temp_root)
        assert before == after, "snapshot changed the fixture"
        assert baseline["SchemaVersion"] == 3
        assert "Complete" not in baseline
        assert baseline["ScanComplete"] is True
        assert baseline["ReviewClassificationComplete"] is True
        assert baseline["Safety"]["AnalysisOnly"] is True
        assert baseline["Safety"]["SnapshotAuthorizesDeletion"] is False
        assert baseline["OutputKind"] == "ReadOnlyDiagnosticSnapshot"
        assert baseline["UsableAsActionManifest"] is False
        assert baseline["RecordsAuthorizeDeletion"] is False
        assert baseline["PathRecordsAuthorizeDeletion"] is False
        assert baseline["Safety"]["RecordsAuthorizeDeletion"] is False
        assert baseline["CodexRoot"]["Path"] == str(codex_root.resolve())
        assert baseline["CodexRoot"]["MeasurementOnly"] is True
        assert baseline["CodexRoot"]["DeletionAuthorized"] is False
        assert baseline["State"]["MeasurementOnly"] is True
        assert baseline["State"]["DeletionAuthorized"] is False
        assert baseline["State"]["Database"]["Path"] == str(database.resolve())
        assert baseline["State"]["Database"]["DeletionAuthorized"] is False
        assert all(row["MeasurementOnly"] for row in baseline["Areas"])
        assert all(row["DeletionAuthorized"] is False for row in baseline["Areas"])
        assert all(row["MeasurementOnly"] for row in baseline["Databases"])
        assert all(row["DeletionAuthorized"] is False for row in baseline["Databases"])
        assert baseline["Safety"]["TaskConsistencyValid"] is True
        assert baseline["Safety"]["TaskAssetReviewClassificationComplete"] is True
        assert baseline["Safety"]["AuthoritativeStateDatabaseResolved"] is True
        assert set(baseline["Safety"]["ProtectedTaskIds"]) == {
            PARENT_ID,
            CHILD_ID,
            GRANDCHILD_ID,
            SIBLING_ID,
        }
        image_records = baseline["GeneratedImages"]["ReviewOnlyHistoricalAssetRecords"]
        visual_records = baseline["Visualizations"]["ReviewOnlyHistoricalAssetRecords"]
        assert len(image_records) == 1
        assert len(visual_records) == 1
        for record in image_records + visual_records:
            assert record["Disposition"] == "ProtectPendingExactSelection"
            assert record["DeletionAuthorized"] is False
            assert record["MeasurementOnly"] is True
            assert record["Classification"] == "EvidenceOnly"
            assert record["ContentUniqueness"] == "NotEvaluated"
            assert record["AmbiguityReasons"]
        image_review_paths = {record["Path"] for record in image_records}
        image_ambiguous_paths = {
            record["Path"]
            for record in baseline["GeneratedImages"]["ProtectedAmbiguousDirectories"]
        }
        visual_review_paths = {record["Path"] for record in visual_records}
        visual_ambiguous_paths = {
            record["Path"]
            for record in baseline["Visualizations"]["ProtectedAmbiguousDirectories"]
        }
        assert image_review_paths.isdisjoint(image_ambiguous_paths)
        assert visual_review_paths.isdisjoint(visual_ambiguous_paths)
        assert baseline["ReportScan"]["Complete"] is True
        assert baseline["ReportScan"]["RecordsAuthorizeDeletion"] is False
        assert baseline["ReportScan"]["Total"] == 3
        assert baseline["ReportScan"]["Truncated"] is False
        report_paths = {
            Path(row["Path"]).name for row in baseline["ReportScan"]["Items"]
        }
        assert all(
            row["MeasurementOnly"] is True
            and row["DeletionAuthorized"] is False
            for row in baseline["ReportScan"]["Items"]
        )
        assert report_paths == {"cleanup-report.md", "audit-summary.md", "handoff.txt"}
        limited_reports = run_snapshot(script, codex_root, project_root, top=1)
        assert limited_reports["ReportScan"]["Total"] == 3
        assert limited_reports["ReportScan"]["Truncated"] is True
        assert len(limited_reports["ReportScan"]["Items"]) == 1
        missing_project = run_snapshot(script, codex_root, temp_root / "missing-project")
        assert missing_project["ReviewClassificationComplete"] is False
        assert missing_project["ReportScan"]["Requested"] is True
        assert missing_project["ReportScan"]["Complete"] is False
        assert missing_project["ReportScan"]["Items"] == []
        assert missing_project["ReportScan"]["SkippedRoots"][0]["DeletionAuthorized"] is False

        no_identity = run_snapshot(script, codex_root, protected=None)
        assert no_identity["ReviewClassificationComplete"] is False
        assert no_identity["Safety"]["TaskAssetReviewClassificationComplete"] is False
        assert no_identity["GeneratedImages"]["ReviewOnlyHistoricalAssetRecords"] == []
        assert no_identity["Visualizations"]["ReviewOnlyHistoricalAssetRecords"] == []

        unknown_identity = run_snapshot(script, codex_root, protected=NESTED_ID)
        assert unknown_identity["Safety"]["CurrentTaskProtectionProvided"] is False
        assert unknown_identity["Safety"]["UnknownProtectedTaskIds"] == [NESTED_ID]
        assert unknown_identity["ScanComplete"] is False
        assert unknown_identity["Safety"]["TaskAssetReviewClassificationComplete"] is False
        assert unknown_identity["GeneratedImages"]["ReviewOnlyHistoricalAssetRecords"] == []

        child_backup = child_rollout.read_bytes()
        child_rollout.unlink()
        missing = run_snapshot(script, codex_root)
        assert missing["ReviewClassificationComplete"] is False
        assert missing["Safety"]["TaskConsistencyValid"] is False
        assert missing["Safety"]["TaskAssetReviewClassificationComplete"] is False
        child_rollout.write_bytes(child_backup)
        make_old(child_rollout.parent)

        duplicate_rollout = session_root / (
            f"rollout-2026-01-01T00-00-02-{CHILD_ID}.jsonl"
        )
        write_rollout(duplicate_rollout, CHILD_ID)
        duplicate = run_snapshot(script, codex_root)
        assert duplicate["ReviewClassificationComplete"] is False
        assert duplicate["Safety"]["TaskConsistencyValid"] is False
        assert duplicate["Safety"]["TaskAssetReviewClassificationComplete"] is False
        assert duplicate["GeneratedImages"]["ReviewOnlyHistoricalAssetRecords"] == []
        duplicate_rollout.unlink()

        stray_rollout = session_root / (
            f"rollout-2026-01-01T00-00-03-{STRAY_ID}.jsonl"
        )
        write_rollout(stray_rollout, STRAY_ID)
        stray = run_snapshot(script, codex_root)
        assert stray["Safety"]["TaskConsistencyValid"] is False
        assert stray["Safety"]["TaskAssetReviewClassificationComplete"] is False
        assert stray["GeneratedImages"]["ReviewOnlyHistoricalAssetRecords"] == []
        stray_rollout.unlink()

        connection = sqlite3.connect(database)
        connection.execute(
            "UPDATE threads SET rollout_path = ? WHERE id = ?",
            (str(temp_root / "wrong-rollout.jsonl"), CHILD_ID),
        )
        connection.commit()
        connection.close()
        path_mismatch = run_snapshot(script, codex_root)
        assert path_mismatch["ReviewClassificationComplete"] is False
        assert path_mismatch["Safety"]["TaskConsistencyValid"] is False
        assert path_mismatch["State"]["RolloutPathMismatches"]
        assert all(
            row["MeasurementOnly"] is True
            and row["DeletionAuthorized"] is False
            for row in path_mismatch["State"]["RolloutPathMismatches"]
        )
        assert path_mismatch["Safety"]["TaskAssetReviewClassificationComplete"] is False
        connection = sqlite3.connect(database)
        connection.execute(
            "UPDATE threads SET rollout_path = ? WHERE id = ?",
            (str(child_rollout.resolve()), CHILD_ID),
        )
        connection.commit()
        connection.close()

        second_database = codex_root / "state_2.sqlite"
        shutil.copy2(database, second_database)
        multiple_databases = run_snapshot(script, codex_root)
        assert multiple_databases["ReviewClassificationComplete"] is False
        assert multiple_databases["Safety"]["AuthoritativeStateDatabaseResolved"] is False
        assert multiple_databases["Safety"]["TaskAssetReviewClassificationComplete"] is False
        second_database.unlink()

        connection = sqlite3.connect(database)
        connection.execute(
            "INSERT INTO thread_spawn_edges VALUES (?, ?)", (PARENT_ID, STRAY_ID)
        )
        connection.commit()
        connection.close()
        dangling_edge = run_snapshot(script, codex_root)
        assert dangling_edge["ReviewClassificationComplete"] is False
        assert dangling_edge["Safety"]["StateDatabaseComplete"] is False
        assert dangling_edge["Safety"]["TaskAssetReviewClassificationComplete"] is False
        connection = sqlite3.connect(database)
        connection.execute(
            "DELETE FROM thread_spawn_edges WHERE child_thread_id = ?", (STRAY_ID,)
        )
        connection.commit()
        connection.close()

        invalid_date = visual_root / "2026" / "99" / "99" / STRAY_ID
        invalid_date.mkdir(parents=True)
        (invalid_date / "visual.json").write_text("invalid date", encoding="utf-8")
        invalid_visual = run_snapshot(script, codex_root)
        assert invalid_visual["ReviewClassificationComplete"] is False
        assert invalid_visual["Safety"]["TaskAssetReviewClassificationComplete"] is False
        shutil.rmtree(visual_root / "2026" / "99")

        duplicate_visual = visual_root / "2026" / "01" / "02" / CHILD_ID
        duplicate_visual.mkdir(parents=True)
        (duplicate_visual / "visual.json").write_text("duplicate", encoding="utf-8")
        duplicate_visual_result = run_snapshot(script, codex_root)
        assert duplicate_visual_result["ReviewClassificationComplete"] is False
        assert (
            duplicate_visual_result["Safety"]["TaskAssetReviewClassificationComplete"]
            is False
        )
        shutil.rmtree(visual_root / "2026" / "01" / "02")

        nested = image_root / "container" / NESTED_ID
        nested.mkdir(parents=True)
        (nested / "image.png").write_bytes(b"nested")
        nested_result = run_snapshot(script, codex_root)
        assert nested_result["ReviewClassificationComplete"] is False
        assert nested_result["Safety"]["TaskAssetReviewClassificationComplete"] is False
        assert nested_result["GeneratedImages"]["ReviewOnlyHistoricalAssetRecords"] == []
        shutil.rmtree(image_root / "container")

        image_backup = codex_root / "generated_images_backup"
        external_images = temp_root / "outside_images"
        external_task = external_images / ORPHAN_ID
        external_task.mkdir(parents=True)
        (external_task / "image.png").write_bytes(b"outside")
        os.replace(image_root, image_backup)
        subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(image_root), str(external_images)],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        reparse_root = run_snapshot(script, codex_root)
        assert reparse_root["ReviewClassificationComplete"] is False
        assert reparse_root["Safety"]["TaskAssetReviewClassificationComplete"] is False
        assert reparse_root["GeneratedImages"]["ReviewOnlyHistoricalAssetRecords"] == []
        os.rmdir(image_root)
        os.replace(image_backup, image_root)

        ancestor_link = temp_root / "ancestor-link"
        subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(ancestor_link), str(temp_root)],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        try:
            ancestor_reparse = subprocess.run(
                [
                    "pwsh",
                    "-NoProfile",
                    "-File",
                    str(script),
                    "-CodexRoot",
                    str(ancestor_link / ".codex"),
                    "-CurrentTaskId",
                    PARENT_ID,
                    "-AsJson",
                ],
                capture_output=True,
                text=True,
                encoding="utf-8",
            )
            assert ancestor_reparse.returncode != 0
            assert "ancestor chain is unsafe" in (
                ancestor_reparse.stdout + ancestor_reparse.stderr
            )
        finally:
            os.rmdir(ancestor_link)

        wal_database = temp_root / "wal_state.sqlite"
        wal_connection = sqlite3.connect(wal_database)
        assert wal_connection.execute("PRAGMA journal_mode = WAL").fetchone()[0] == "wal"
        wal_connection.executescript(
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                archived INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE thread_spawn_edges (
                parent_thread_id TEXT NOT NULL,
                child_thread_id TEXT NOT NULL
            );
            """
        )
        wal_connection.execute(
            "INSERT INTO threads VALUES (?, ?, ?, ?)",
            (PARENT_ID, str(parent_rollout.resolve()), 0, old_timestamp),
        )
        wal_connection.commit()
        wal_connection.execute("SELECT COUNT(*) FROM threads").fetchone()
        wal_paths = [
            wal_database,
            Path(str(wal_database) + "-wal"),
            Path(str(wal_database) + "-shm"),
        ]
        wal_before = selected_file_manifest(wal_paths)
        helper = script.with_name("read_codex_state.py")
        helper_run = subprocess.run(
            [sys.executable, "-I", "-B", str(helper), str(wal_database)],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        assert json.loads(helper_run.stdout)["complete"] is True
        wal_after = selected_file_manifest(wal_paths)
        assert wal_before == wal_after, "read-only helper changed DB/WAL/SHM"
        wal_connection.close()

        invalid_range = subprocess.run(
            [
                "pwsh",
                "-NoProfile",
                "-File",
                str(script),
                "-CodexRoot",
                str(codex_root),
                "-ProtectRecentDays",
                "0",
                "-AsJson",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        assert invalid_range.returncode != 0

    print("PASS: isolated snapshot safety regression tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
