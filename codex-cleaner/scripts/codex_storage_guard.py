#!/usr/bin/env python3
"""Read-only, format-agnostic Codex storage assessment."""

from __future__ import annotations

import argparse
import heapq
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ASSESSMENT_SCHEMA_VERSION = 2
SUPPORTED_DOCTOR_SCHEMA = 1
KNOWN_TASK_ACTIONS = ("archive", "delete", "unarchive")


class GuardError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class CommandResult:
    exit_code: int
    stdout: str
    stderr: str
    timed_out: bool


class SubprocessRunner:
    def run(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        env: Mapping[str, str],
        timeout_seconds: int,
    ) -> CommandResult:
        try:
            completed = subprocess.run(
                [str(value) for value in argv],
                cwd=str(cwd),
                env=dict(env),
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                shell=False,
                check=False,
                timeout=timeout_seconds,
            )
        except subprocess.TimeoutExpired as exc:
            return CommandResult(
                -1,
                _coerce_timeout_output(exc.stdout),
                _coerce_timeout_output(exc.stderr),
                True,
            )
        except OSError as exc:
            raise GuardError(
                "codex-execution-failed", f"Codex could not be started: {exc}"
            ) from exc
        return CommandResult(
            completed.returncode, completed.stdout, completed.stderr, False
        )


def _coerce_timeout_output(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _iso_utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _is_linklike(metadata: os.stat_result) -> bool:
    if stat.S_ISLNK(metadata.st_mode):
        return True
    attributes = getattr(metadata, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(attributes & reparse_flag)


def _absolute(path: Path) -> Path:
    return Path(os.path.abspath(os.path.expanduser(str(path))))


def _canonical_directory(path: Path, *, kind: str) -> Path:
    requested = _absolute(path)
    try:
        requested_metadata = os.lstat(requested)
    except OSError as exc:
        raise GuardError(
            f"{kind}-unavailable", f"{kind} is unavailable: {requested}: {exc}"
        ) from exc
    if _is_linklike(requested_metadata):
        raise GuardError(
            f"unsafe-{kind}",
            f"{kind} must not be a symlink, junction, or reparse point",
        )
    try:
        resolved = requested.resolve(strict=True)
        metadata = os.stat(resolved, follow_symlinks=False)
    except OSError as exc:
        raise GuardError(
            f"{kind}-unavailable", f"{kind} is unavailable: {requested}: {exc}"
        ) from exc
    if not stat.S_ISDIR(metadata.st_mode) or _is_linklike(metadata):
        raise GuardError(f"{kind}-unavailable", f"{kind} must be a regular directory")
    return resolved


def _canonical_executable(path: Path) -> Path:
    try:
        resolved = path.expanduser().resolve(strict=True)
        metadata = os.stat(resolved, follow_symlinks=False)
    except OSError as exc:
        raise GuardError(
            "codex-executable-unavailable", f"Codex executable is unavailable: {exc}"
        ) from exc
    if not stat.S_ISREG(metadata.st_mode) or _is_linklike(metadata):
        raise GuardError(
            "unsafe-codex-executable", "Codex target must be a regular non-link file"
        )
    if os.name == "nt" and resolved.suffix.lower() != ".exe":
        raise GuardError(
            "unsafe-codex-executable", "Codex must resolve to a native .exe on Windows"
        )
    if os.name != "nt" and not os.access(resolved, os.X_OK):
        raise GuardError("unsafe-codex-executable", "Codex target is not executable")
    return resolved


class CodexClient:
    def __init__(
        self,
        executable: Path,
        codex_home: Path,
        *,
        runner: Any | None = None,
    ) -> None:
        self.executable = _canonical_executable(executable)
        self.codex_home = _canonical_directory(codex_home, kind="codex-home")
        self.runner = runner if runner is not None else SubprocessRunner()

    def _run(self, *args: str, timeout_seconds: int = 60) -> CommandResult:
        environment = dict(os.environ)
        environment["CODEX_HOME"] = str(self.codex_home)
        return self.runner.run(
            [str(self.executable), *args],
            cwd=self.codex_home,
            env=environment,
            timeout_seconds=timeout_seconds,
        )

    def version(self) -> str:
        result = self._run("--version", timeout_seconds=20)
        if result.timed_out or result.exit_code != 0:
            raise GuardError("codex-version-unavailable", "Codex version probe failed")
        version = result.stdout.strip()
        if not version or len(version) > 256:
            raise GuardError(
                "codex-version-unavailable", "Codex returned an invalid version"
            )
        return version

    def doctor(self) -> dict[str, Any]:
        result = self._run("doctor", "--json", timeout_seconds=120)
        if result.timed_out or result.exit_code != 0:
            raise GuardError("doctor-unavailable", "codex doctor --json failed")
        payload = _strict_json_loads(result.stdout, source="doctor output")
        if not isinstance(payload, dict):
            raise GuardError("doctor-invalid", "Doctor output must be a JSON object")
        schema = payload.get("schemaVersion")
        status = payload.get("overallStatus")
        version = payload.get("codexVersion")
        if not isinstance(schema, int) or isinstance(schema, bool):
            raise GuardError(
                "doctor-invalid", "Doctor schemaVersion is missing or invalid"
            )
        if not isinstance(status, str) or not isinstance(version, str):
            raise GuardError("doctor-invalid", "Doctor status or version is missing")
        return {
            "schemaVersion": schema,
            "schemaRecognized": schema == SUPPORTED_DOCTOR_SCHEMA,
            "overallStatus": status,
            "codexVersion": version,
        }

    def probe_capability(self, action: str) -> dict[str, str]:
        if action not in KNOWN_TASK_ACTIONS:
            return {"status": "unknown", "reason": "action-not-recognized-by-guard"}
        try:
            result = self._run(action, "--help", timeout_seconds=20)
        except GuardError as exc:
            return {"status": "unknown", "reason": exc.code}
        if result.timed_out:
            return {"status": "unknown", "reason": "probe-timeout"}
        if result.exit_code != 0:
            return {"status": "unknown", "reason": "probe-nonzero"}
        usage = re.compile(
            rf"(?mi)^Usage:\s+codex(?:\.exe)?\s+{re.escape(action)}\b[^\r\n]*<SESSION>"
        )
        if usage.search(result.stdout) is None:
            return {"status": "unknown", "reason": "contract-unrecognized"}
        if (
            action == "delete"
            and re.search(r"(?m)^\s+--force\b", result.stdout) is None
        ):
            return {"status": "unknown", "reason": "force-contract-unrecognized"}
        return {"status": "supported"}


def _strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise GuardError("duplicate-json-key", f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> None:
    raise GuardError("invalid-json-number", f"Invalid JSON number: {value}")


def _strict_json_loads(text: str, *, source: str) -> Any:
    try:
        return json.loads(
            text,
            object_pairs_hook=_strict_object,
            parse_constant=_reject_json_constant,
        )
    except GuardError:
        raise
    except (json.JSONDecodeError, TypeError) as exc:
        raise GuardError("invalid-json", f"Could not parse {source} as JSON") from exc


def _scan_entry(
    path: Path,
    *,
    largest: list[tuple[int, str]],
    top: int,
    limitations: list[dict[str, str]],
) -> tuple[int, int, bool]:
    stack = [path]
    apparent_bytes = 0
    file_count = 0
    complete = True
    while stack:
        current = stack.pop()
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            complete = False
            limitations.append({"kind": "changed-during-scan", "path": str(current)})
            continue
        except OSError as exc:
            complete = False
            limitations.append(
                {"kind": "unreadable", "path": str(current), "detail": str(exc)}
            )
            continue

        if _is_linklike(metadata):
            complete = False
            limitations.append({"kind": "link-skipped", "path": str(current)})
            continue
        if stat.S_ISREG(metadata.st_mode):
            size = metadata.st_size
            apparent_bytes += size
            file_count += 1
            candidate = (size, str(current))
            if top > 0 and len(largest) < top:
                heapq.heappush(largest, candidate)
            elif top > 0 and candidate > largest[0]:
                heapq.heapreplace(largest, candidate)
            continue
        if not stat.S_ISDIR(metadata.st_mode):
            complete = False
            limitations.append({"kind": "special-file-skipped", "path": str(current)})
            continue
        try:
            if os.path.ismount(current):
                complete = False
                limitations.append(
                    {"kind": "nested-mount-skipped", "path": str(current)}
                )
                continue
        except OSError as exc:
            complete = False
            limitations.append(
                {
                    "kind": "mount-check-failed",
                    "path": str(current),
                    "detail": str(exc),
                }
            )
            continue
        try:
            with os.scandir(current) as entries:
                children = sorted(Path(entry.path) for entry in entries)
        except OSError as exc:
            complete = False
            limitations.append(
                {"kind": "unreadable", "path": str(current), "detail": str(exc)}
            )
            continue
        try:
            after = os.lstat(current)
        except OSError as exc:
            complete = False
            limitations.append(
                {
                    "kind": "directory-changed-during-scan",
                    "path": str(current),
                    "detail": str(exc),
                }
            )
            continue
        if _is_linklike(after) or (after.st_dev, after.st_ino) != (
            metadata.st_dev,
            metadata.st_ino,
        ):
            complete = False
            limitations.append(
                {"kind": "directory-changed-during-scan", "path": str(current)}
            )
            continue
        stack.extend(reversed(children))
    return apparent_bytes, file_count, complete


def scan_storage(codex_home: Path, top: int = 20) -> dict[str, Any]:
    if top < 0 or top > 1000:
        raise GuardError("invalid-top", "top must be between 0 and 1000")
    root = _canonical_directory(codex_home, kind="codex-home")
    started = _utc_now()
    limitations: list[dict[str, str]] = []
    largest: list[tuple[int, str]] = []
    areas: list[dict[str, Any]] = []
    try:
        with os.scandir(root) as entries:
            children = sorted(
                (Path(entry.path) for entry in entries), key=lambda value: value.name
            )
    except OSError as exc:
        children = []
        limitations.append(
            {"kind": "unreadable", "path": str(root), "detail": str(exc)}
        )

    for child in children:
        apparent_bytes, file_count, complete = _scan_entry(
            child,
            largest=largest,
            top=top,
            limitations=limitations,
        )
        areas.append(
            {
                "name": child.name,
                "path": str(child),
                "apparentBytes": apparent_bytes,
                "fileCount": file_count,
                "complete": complete,
            }
        )

    areas.sort(key=lambda value: (-value["apparentBytes"], value["name"]))
    complete_within_root = not limitations and all(area["complete"] for area in areas)
    return {
        "schemaVersion": ASSESSMENT_SCHEMA_VERSION,
        "observedFrom": _iso_utc(started),
        "observedTo": _iso_utc(_utc_now()),
        "consistency": "live-best-effort",
        "root": str(root),
        "apparentBytes": sum(area["apparentBytes"] for area in areas),
        "fileCount": sum(area["fileCount"] for area in areas),
        "areas": areas,
        "largestFiles": [
            {"path": path, "apparentBytes": size}
            for size, path in sorted(largest, reverse=True)
        ],
        "coverage": {
            "scope": "codex-home-only",
            "completeWithinRoot": complete_within_root,
            "externalStateRootsMeasured": False,
            "externalStateRootEnvironmentHint": os.environ.get("CODEX_SQLITE_HOME"),
        },
        "limitations": limitations,
        "measurementNotes": [
            "Apparent bytes are not allocated bytes and may count hard links more than once.",
            "The live scan is not an atomic snapshot and never authorizes deletion.",
            "Links and mounts are skipped when observed; stdlib traversal is not race-free.",
            "Completeness applies only to CODEX_HOME; state roots configured elsewhere are not measured.",
        ],
        "safety": {
            "analysisOnly": True,
            "authorizesDeletion": False,
            "linkPolicy": "skip-when-observed",
            "raceFreeTraversal": False,
        },
    }


def assess_storage(
    codex_home: Path,
    *,
    codex_client: CodexClient | None = None,
    top: int = 20,
) -> dict[str, Any]:
    assessment = scan_storage(codex_home, top=top)
    codex: dict[str, Any] = {"available": codex_client is not None}
    if codex_client is not None:
        try:
            codex["version"] = codex_client.version()
        except GuardError as exc:
            codex["versionError"] = exc.code
        try:
            codex["doctor"] = codex_client.doctor()
        except GuardError as exc:
            codex["doctor"] = {"available": False, "error": exc.code}
        codex["capabilities"] = {
            action: codex_client.probe_capability(action)
            for action in KNOWN_TASK_ACTIONS
        }
    codex["guardPolicy"] = {
        "archive": "blocked-affected-set-preview-unavailable",
        "delete": "blocked-affected-set-preview-unavailable",
        "unarchive": "outside-storage-cleanup-use-official-interface",
    }
    assessment["codex"] = codex
    return assessment


def _resolve_codex_home(value: str | None) -> Path:
    if value:
        return Path(value)
    configured = os.environ.get("CODEX_HOME")
    if configured:
        return Path(configured)
    return Path.home() / ".codex"


def _resolve_codex_executable(value: str | None) -> Path | None:
    if value:
        return Path(value)
    discovered = shutil.which("codex")
    return Path(discovered) if discovered else None


def _emit_json(value: object, *, stream: Any = sys.stdout) -> None:
    json.dump(
        value, stream, ensure_ascii=False, allow_nan=False, sort_keys=True, indent=2
    )
    stream.write("\n")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Inspect opaque Codex storage without authorizing or performing cleanup."
    )
    parser.add_argument("--codex-home")
    parser.add_argument("--codex-executable")
    parser.add_argument("--top", type=int, default=20)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        home = _resolve_codex_home(args.codex_home)
        executable = _resolve_codex_executable(args.codex_executable)
        client = CodexClient(executable, home) if executable is not None else None
        _emit_json(assess_storage(home, codex_client=client, top=args.top))
        return 0
    except GuardError as exc:
        _emit_json(
            {"error": {"code": exc.code, "message": str(exc)}}, stream=sys.stderr
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
