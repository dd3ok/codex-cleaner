from __future__ import annotations

import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import codex_storage_guard as guard


class FakeRunner:
    def __init__(self) -> None:
        self.calls: list[list[str]] = []
        self.contexts: list[dict[str, object]] = []
        self.help_exit_codes: dict[str, int] = {}
        self.version_exit_code = 0
        self.doctor_payload: object = {
            "schemaVersion": 1,
            "overallStatus": "ok",
            "codexVersion": "0.147.0",
            "checks": [{"volatile": "nested details are ignored"}],
        }

    def run(self, argv, *, cwd, env, timeout_seconds):
        args = [str(value) for value in argv]
        self.calls.append(args)
        self.contexts.append(
            {"cwd": Path(cwd), "env": dict(env), "timeoutSeconds": timeout_seconds}
        )
        tail = args[1:]
        if tail == ["--version"]:
            return guard.CommandResult(
                self.version_exit_code,
                "codex-cli 0.147.0\n" if self.version_exit_code == 0 else "",
                "simulated failure" if self.version_exit_code else "",
                False,
            )
        if tail == ["doctor", "--json"]:
            return guard.CommandResult(0, json.dumps(self.doctor_payload), "", False)
        if len(tail) == 2 and tail[1] == "--help":
            exit_code = self.help_exit_codes.get(tail[0], 0)
            force = "\n      --force\n" if tail[0] == "delete" else ""
            return guard.CommandResult(
                exit_code,
                f"Usage: codex {tail[0]} [OPTIONS] <SESSION>{force}",
                "simulated failure" if exit_code else "",
                False,
            )
        raise AssertionError(f"unexpected command: {args}")


class StorageGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.codex_home = self.root / "codex-home"
        self.codex_home.mkdir()
        self.binary = self.root / ("codex.exe" if os.name == "nt" else "codex")
        self.binary.write_bytes(b"fake-codex")
        if os.name != "nt":
            self.binary.chmod(0o700)
        self.runner = FakeRunner()
        self.client = guard.CodexClient(
            self.binary,
            self.codex_home,
            probe_cwd=self.root,
            runner=self.runner,
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_future_opaque_area_is_measured_without_content_change(self) -> None:
        future = self.codex_home / "future-v9-store"
        future.mkdir()
        payload = future / "opaque.bin"
        payload.write_bytes(b"x" * 37)
        before = hashlib.sha256(payload.read_bytes()).hexdigest()

        result = guard.scan_storage(self.codex_home, top=5)

        areas = {area["name"]: area for area in result["areas"]}
        self.assertEqual(areas["future-v9-store"]["apparentBytes"], 37)
        self.assertEqual(result["coverage"]["scope"], "codex-home-only")
        self.assertTrue(result["coverage"]["completeWithinRoot"])
        self.assertFalse(result["safety"]["authorizesDeletion"])
        self.assertEqual(result["safety"]["linkPolicy"], "skip-when-observed")
        self.assertFalse(result["safety"]["raceFreeTraversal"])
        self.assertEqual(hashlib.sha256(payload.read_bytes()).hexdigest(), before)

    def test_equal_size_largest_files_have_stable_path_tiebreaker(self) -> None:
        area = self.codex_home / "area"
        area.mkdir()
        for name in ("c.bin", "a.bin", "b.bin"):
            (area / name).write_bytes(b"same")

        first = guard.scan_storage(self.codex_home, top=2)["largestFiles"]
        second = guard.scan_storage(self.codex_home, top=2)["largestFiles"]

        self.assertEqual(first, second)
        self.assertEqual(
            [Path(item["path"]).name for item in first], ["c.bin", "b.bin"]
        )

    def test_internal_junction_is_skipped_and_marks_root_incomplete(self) -> None:
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "secret.bin").write_bytes(b"never traverse")
        link = self.codex_home / "linked"
        if os.name == "nt":
            command = "New-Item -ItemType Junction -Path $env:GUARD_LINK -Target $env:GUARD_TARGET | Out-Null"
            environment = dict(os.environ)
            environment["GUARD_LINK"] = str(link)
            environment["GUARD_TARGET"] = str(outside)
            created = subprocess.run(
                [
                    "pwsh.exe",
                    "-NoLogo",
                    "-NoProfile",
                    "-NonInteractive",
                    "-Command",
                    command,
                ],
                capture_output=True,
                text=True,
                env=environment,
                check=False,
            )
            if created.returncode != 0:
                self.skipTest(f"junctions are unavailable: {created.stderr}")
        else:
            try:
                link.symlink_to(outside, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks are unavailable: {exc}")

        try:
            result = guard.scan_storage(self.codex_home)
            self.assertFalse(result["coverage"]["completeWithinRoot"])
            self.assertTrue(
                any(item["kind"] == "link-skipped" for item in result["limitations"])
            )
            self.assertNotIn(
                "secret.bin",
                {Path(item["path"]).name for item in result["largestFiles"]},
            )
        finally:
            if os.name == "nt":
                os.rmdir(link)
            else:
                link.unlink()

    def test_external_state_scope_is_explicit(self) -> None:
        previous = os.environ.get("CODEX_SQLITE_HOME")
        os.environ["CODEX_SQLITE_HOME"] = str(self.root / "external-state")
        try:
            result = guard.scan_storage(self.codex_home)
        finally:
            if previous is None:
                os.environ.pop("CODEX_SQLITE_HOME", None)
            else:
                os.environ["CODEX_SQLITE_HOME"] = previous

        coverage = result["coverage"]
        self.assertFalse(coverage["externalStateRootsMeasured"])
        self.assertEqual(
            coverage["sqliteHomeEnvironmentHint"],
            str(self.root / "external-state"),
        )
        self.assertNotIn("externalStateRootEnvironmentHint", coverage)

    def test_doctor_is_opt_in_and_not_run_by_default(self) -> None:
        result = guard.assess_storage(self.codex_home, codex_client=self.client, top=0)

        self.assertEqual(result["codex"]["doctor"], {"status": "not-requested"})
        self.assertNotIn(
            [str(self.binary.resolve()), "doctor", "--json"], self.runner.calls
        )

    def test_unknown_doctor_schema_is_reported_not_interpreted(self) -> None:
        self.runner.doctor_payload = {
            "schemaVersion": 2,
            "overallStatus": "ok",
            "codexVersion": "future",
            "checks": {"completely": "different"},
        }

        result = guard.assess_storage(
            self.codex_home,
            codex_client=self.client,
            include_doctor=True,
            top=0,
        )

        self.assertEqual(result["codex"]["doctor"]["schemaVersion"], 2)
        self.assertFalse(result["codex"]["doctor"]["schemaRecognized"])
        self.assertTrue(result["codex"]["doctor"]["available"])
        self.assertNotIn("overallStatus", result["codex"]["doctor"])
        self.assertNotIn("codexVersion", result["codex"]["doctor"])
        self.assertEqual(
            result["codex"]["guardPolicy"]["delete"],
            "blocked-affected-set-preview-unavailable",
        )

    def test_malformed_doctor_does_not_break_read_only_inventory(self) -> None:
        self.runner.doctor_payload = ["wrong shape"]

        result = guard.assess_storage(
            self.codex_home,
            codex_client=self.client,
            include_doctor=True,
            top=0,
        )

        self.assertEqual(result["codex"]["doctor"]["error"], "doctor-invalid")
        self.assertFalse(result["codex"]["available"])
        self.assertEqual(
            result["codex"]["capabilities"]["archive"], {"status": "supported"}
        )
        self.assertFalse(result["safety"]["authorizesDeletion"])

    def test_failed_capability_probe_marks_optional_adapter_unavailable(self) -> None:
        self.runner.help_exit_codes["delete"] = 1

        result = guard.assess_storage(self.codex_home, codex_client=self.client, top=0)

        self.assertFalse(result["codex"]["available"])
        self.assertEqual(
            result["codex"]["capabilities"]["delete"],
            {"status": "unknown", "reason": "probe-nonzero"},
        )

    def test_failed_version_probe_isolated_from_inventory_and_other_probes(self) -> None:
        self.runner.version_exit_code = 1

        result = guard.assess_storage(
            self.codex_home,
            codex_client=self.client,
            include_doctor=True,
            top=0,
        )

        self.assertFalse(result["codex"]["available"])
        self.assertEqual(
            result["codex"]["doctor"],
            {"available": False, "error": "codex-version-unavailable"},
        )
        self.assertEqual(
            result["codex"]["capabilities"]["archive"],
            {"status": "unknown", "reason": "codex-version-unavailable"},
        )
        self.assertEqual(len(self.runner.calls), 1)

    def test_probe_uses_caller_selected_cwd(self) -> None:
        self.client.version()

        self.assertEqual(self.runner.contexts[-1]["cwd"], self.root)
        self.assertEqual(
            self.runner.contexts[-1]["env"]["CODEX_HOME"], str(self.codex_home)
        )

    def test_capability_probe_is_advisory_and_no_mutator_exists(self) -> None:
        result = guard.assess_storage(self.codex_home, codex_client=self.client, top=0)

        self.assertEqual(
            result["codex"]["capabilities"],
            {
                "archive": {"status": "supported"},
                "delete": {"status": "supported"},
                "unarchive": {"status": "supported"},
            },
        )
        self.assertFalse(hasattr(self.client, "run_action"))
        self.assertFalse(hasattr(guard, "create_plan"))
        self.assertFalse(hasattr(guard, "apply_plan"))
        self.assertEqual(
            result["codex"]["guardPolicy"]["unarchive"],
            "outside-storage-cleanup-not-run-by-this-skill",
        )

    def test_capability_probe_failure_is_unknown_and_isolated(self) -> None:
        self.runner.help_exit_codes["delete"] = 9

        result = guard.assess_storage(self.codex_home, codex_client=self.client, top=0)

        self.assertEqual(
            result["codex"]["capabilities"]["delete"],
            {"status": "unknown", "reason": "probe-nonzero"},
        )
        self.assertEqual(
            result["codex"]["capabilities"]["archive"], {"status": "supported"}
        )

    def test_missing_root_fails_without_creating_it(self) -> None:
        missing = self.root / "missing"
        with self.assertRaises(guard.GuardError) as raised:
            guard.scan_storage(missing)
        self.assertEqual(raised.exception.code, "codex-home-unavailable")
        self.assertFalse(missing.exists())

    def test_unsafe_optional_codex_launcher_does_not_block_inventory(self) -> None:
        unsafe = self.root / ("codex.cmd" if os.name == "nt" else "codex-wrapper")
        unsafe.write_text("unsafe wrapper", encoding="utf-8")
        stdout = io.StringIO()
        stderr = io.StringIO()

        previous_stdout, previous_stderr = sys.stdout, sys.stderr
        try:
            sys.stdout, sys.stderr = stdout, stderr
            exit_code = guard.main(
                [
                    "--codex-home",
                    str(self.codex_home),
                    "--codex-executable",
                    str(unsafe),
                    "--doctor",
                    "--top",
                    "0",
                ]
            )
        finally:
            sys.stdout, sys.stderr = previous_stdout, previous_stderr

        payload = json.loads(stdout.getvalue())
        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(payload["root"], str(self.codex_home.resolve()))
        self.assertFalse(payload["codex"]["available"])
        self.assertEqual(payload["codex"]["error"], "unsafe-codex-executable")
        self.assertEqual(
            payload["codex"]["doctor"],
            {"available": False, "error": "codex-unavailable"},
        )


if __name__ == "__main__":
    unittest.main()
