#!/usr/bin/env python3
"""Read a Codex state database without modifying it."""

from __future__ import annotations

import json
import re
import sqlite3
import sys
from pathlib import Path

UUID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def state_fingerprint(database_path: Path) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for path in (
        database_path,
        Path(str(database_path) + "-wal"),
        Path(str(database_path) + "-shm"),
    ):
        try:
            stat = path.stat()
            records.append(
                {
                    "path": str(path),
                    "exists": True,
                    "size": stat.st_size,
                    "mtime_ns": stat.st_mtime_ns,
                }
            )
        except FileNotFoundError:
            records.append({"path": str(path), "exists": False})
    return records


def emit(payload: dict[str, object], exit_code: int) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    raise SystemExit(exit_code)


def main() -> None:
    if len(sys.argv) != 2:
        emit({"complete": False, "errors": ["expected one database path"]}, 2)

    database_path = Path(sys.argv[1]).resolve()
    result: dict[str, object] = {
        "schema_version": 1,
        "database_path": str(database_path),
        "complete": False,
        "errors": [],
        "threads": [],
        "edges": [],
    }

    if not database_path.is_file():
        result["errors"] = ["state database does not exist"]
        emit(result, 1)

    connection: sqlite3.Connection | None = None
    try:
        fingerprint_before = state_fingerprint(database_path)
        uri = f"{database_path.as_uri()}?mode=ro"
        connection = sqlite3.connect(uri, uri=True, timeout=0.25)
        connection.execute("PRAGMA query_only = ON")
        connection.execute("PRAGMA busy_timeout = 250")
        data_version_before = connection.execute("PRAGMA data_version").fetchone()[0]
        connection.execute("BEGIN")

        tables = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
        }
        required_tables = {"threads", "thread_spawn_edges"}
        missing_tables = sorted(required_tables - tables)
        if missing_tables:
            result["errors"] = [
                f"unsupported state schema; missing tables: {', '.join(missing_tables)}"
            ]
            emit(result, 1)

        thread_columns = {
            row[1] for row in connection.execute('PRAGMA table_info("threads")')
        }
        required_thread_columns = {"id", "rollout_path", "archived", "updated_at"}
        missing_columns = sorted(required_thread_columns - thread_columns)
        if missing_columns:
            result["errors"] = [
                "unsupported threads schema; missing columns: "
                + ", ".join(missing_columns)
            ]
            emit(result, 1)

        edge_columns = {
            row[1]
            for row in connection.execute('PRAGMA table_info("thread_spawn_edges")')
        }
        required_edge_columns = {"parent_thread_id", "child_thread_id"}
        missing_edge_columns = sorted(required_edge_columns - edge_columns)
        if missing_edge_columns:
            result["errors"] = [
                "unsupported thread_spawn_edges schema; missing columns: "
                + ", ".join(missing_edge_columns)
            ]
            emit(result, 1)

        thread_rows = list(
            connection.execute(
                "SELECT id, rollout_path, archived, updated_at FROM threads ORDER BY id"
            )
        )
        threads = [
            {
                "id": row[0],
                "rollout_path": row[1],
                "archived": bool(row[2]),
                "updated_at": row[3],
            }
            for row in thread_rows
        ]
        edges = [
            {"parent": row[0], "child": row[1]}
            for row in connection.execute(
                "SELECT parent_thread_id, child_thread_id "
                "FROM thread_spawn_edges ORDER BY parent_thread_id, child_thread_id"
            )
        ]
        connection.execute("COMMIT")
        data_version_after = connection.execute("PRAGMA data_version").fetchone()[0]
        connection.close()
        connection = None
        fingerprint_after = state_fingerprint(database_path)

        invalid_ids = [
            row["id"]
            for row in threads
            if not isinstance(row["id"], str) or not UUID_PATTERN.fullmatch(row["id"])
        ]
        if invalid_ids:
            result["errors"] = [
                f"state database contains {len(invalid_ids)} invalid thread IDs"
            ]
            emit(result, 1)

        invalid_threads = [
            row[0]
            for row in thread_rows
            if not isinstance(row[1], str)
            or not row[1].strip()
            or row[2] not in (0, 1)
            or not isinstance(row[3], (int, float))
        ]
        if invalid_threads:
            result["errors"] = [
                f"state database contains {len(invalid_threads)} invalid thread records"
            ]
            emit(result, 1)

        thread_ids = {row["id"] for row in threads}
        invalid_edges = [
            edge
            for edge in edges
            if not isinstance(edge["parent"], str)
            or not UUID_PATTERN.fullmatch(edge["parent"])
            or not isinstance(edge["child"], str)
            or not UUID_PATTERN.fullmatch(edge["child"])
            or edge["parent"] not in thread_ids
            or edge["child"] not in thread_ids
        ]
        if invalid_edges:
            result["errors"] = [
                f"state database contains {len(invalid_edges)} invalid graph edges"
            ]
            emit(result, 1)

        if data_version_before != data_version_after:
            result["errors"] = ["state database changed during the read transaction"]
            emit(result, 1)
        if fingerprint_before != fingerprint_after:
            result["errors"] = ["state database or WAL/SHM metadata changed during capture"]
            emit(result, 1)

        result["threads"] = threads
        result["edges"] = edges
        result["complete"] = True
        emit(result, 0)
    except (OSError, sqlite3.Error) as exc:
        result["errors"] = [f"{type(exc).__name__}: {exc}"]
        emit(result, 1)
    finally:
        if connection is not None:
            connection.close()


if __name__ == "__main__":
    main()
