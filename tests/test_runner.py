import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

from lib import runner


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER = os.path.join(ROOT, "lib", "runner.py")
FAKE = os.path.join(ROOT, "tests", "fake-opencode")
ISOLATED = os.path.join(ROOT, "share", "opencode-isolated")


def _alive(pid):
    if os.name == "nt":
        result = subprocess.run(
            ["tasklist", "/FI", "PID eq %d" % pid, "/NH"],
            capture_output=True,
            text=True,
        )
        return str(pid) in result.stdout
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.project = os.path.join(self.tmp.name, "project")
        os.makedirs(self.project)
        self.log = os.path.join(self.tmp.name, "argv.jsonl")
        self.pid_file = os.path.join(self.tmp.name, "pid.txt")
        self.env = os.environ.copy()
        self.env["HH_OPENCODE"] = sys.executable + " " + FAKE
        self.env["FAKE_ARGV_LOG"] = self.log
        self.env["FAKE_PID_FILE"] = self.pid_file
        self.env["PYTHONIOENCODING"] = "utf-8"
        for name in ("OPENCODE_CONFIG", "XDG_CONFIG_HOME", "FAKE_MODE", "FAKE_EDIT_FILE"):
            self.env.pop(name, None)

    def invoke(self, extra=None, child=None, env=None, timeout=40):
        command = [sys.executable, RUNNER]
        if extra:
            command.extend(extra)
        command.append("--")
        command.extend(
            child
            or [
                "run",
                "--agent",
                "build",
                "-m",
                "provider/model-name",
                "--file",
                "spec.md",
                "message",
            ]
        )
        return subprocess.run(
            command,
            cwd=self.project,
            env=env or self.env,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def argv_records(self):
        with open(self.log, encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]

    def assert_gone(self, pid):
        deadline = time.time() + 5
        while time.time() < deadline:
            if not _alive(pid):
                return
            time.sleep(0.2)
        self.fail("child %d is still running" % pid)

    def test_ok_run(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Done. RESULT: ok", result.stdout)
        record = self.argv_records()[-1]
        self.assertEqual(record["argv"][0], "run")
        self.assertIn("--format", record["argv"])
        self.assertIn("json", record["argv"])
        self.assertIn("--standalone", record["argv"])
        self.assertEqual(record["argv"][-1], "message")
        self.assertEqual(
            os.path.normcase(record["XDG_CONFIG_HOME"]), os.path.normcase(ISOLATED)
        )

    def test_unicode_output_with_legacy_console(self):
        self.env["FAKE_MODE"] = "unicode"
        self.env["PYTHONIOENCODING"] = "cp1252"
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Done. RESULT: ok", result.stdout)
        self.assertIn("next", result.stdout)
        self.assertNotIn("UnicodeEncodeError", result.stderr)
        self.assertNotIn("Exception in thread", result.stderr)

    def test_upstream_errors_return_six(self):
        self.env["FAKE_MODE"] = "upstream"
        result = self.invoke()
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertIn("provider error", result.stdout.lower())

    def test_loop_returns_four(self):
        self.env["FAKE_MODE"] = "loop"
        result = self.invoke()
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)

    def test_stall_returns_125_and_kills_child(self):
        self.env["FAKE_MODE"] = "stall"
        result = self.invoke(["--idle", "2"])
        self.assertEqual(result.returncode, 125, result.stdout + result.stderr)
        with open(self.pid_file, encoding="utf-8") as handle:
            pid = int(handle.read().strip())
        self.assert_gone(pid)

    def test_timeout_returns_124_and_kills_child(self):
        self.env["FAKE_MODE"] = "slow"
        result = self.invoke(["--timeout", "3"])
        self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
        with open(self.pid_file, encoding="utf-8") as handle:
            pid = int(handle.read().strip())
        self.assert_gone(pid)

    def test_unfinished_check_is_opt_in(self):
        self.env["FAKE_MODE"] = "unfinished"
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.invoke(["--unfinished-check"])
        self.assertEqual(result.returncode, 3, result.stderr)

    def test_sync_appends_sentence_only_with_flag(self):
        self.invoke()
        self.assertEqual(self.argv_records()[-1]["argv"][-1], "message")
        self.invoke(["--sync"])
        last = self.argv_records()[-1]["argv"][-1]
        self.assertTrue(last.startswith("message "))
        self.assertIn(runner.SYNC, last)

    def test_existing_format_flag_is_not_duplicated(self):
        result = self.invoke(
            child=[
                "run",
                "--format=json",
                "--agent",
                "build",
                "-m",
                "provider/model-name",
                "--file",
                "spec.md",
                "message",
            ]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = self.argv_records()[-1]["argv"]
        self.assertNotIn("--format", argv)
        self.assertIn("--format=json", argv)

    def test_no_standalone_omits_flag(self):
        self.invoke(["--no-standalone"])
        self.assertNotIn("--standalone", self.argv_records()[-1]["argv"])

    def test_no_isolate_keeps_config_home(self):
        self.env["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "keep")
        self.invoke(["--no-isolate"])
        self.assertEqual(
            self.argv_records()[-1]["XDG_CONFIG_HOME"],
            os.path.join(self.tmp.name, "keep"),
        )

    def test_missing_opencode_exits_two(self):
        env = dict(self.env)
        env.pop("HH_OPENCODE", None)
        env["PATH"] = ""
        result = self.invoke(env=env)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("opencode not found", result.stderr)

    def test_resolve_executable_splits_versioned_python(self):
        old = os.environ.get("HH_OPENCODE")
        try:
            os.environ["HH_OPENCODE"] = "/opt/homebrew/bin/python3.15 /tmp/fake-opencode"
            self.assertEqual(
                runner._resolve_executable(),
                ["/opt/homebrew/bin/python3.15", "/tmp/fake-opencode"],
            )
            os.environ["HH_OPENCODE"] = (
                "C:\\hostedtoolcache\\Python\\3.12.10\\x64\\python3.exe "
                "C:\\work\\fake-opencode"
            )
            self.assertEqual(
                runner._resolve_executable(),
                [
                    "C:\\hostedtoolcache\\Python\\3.12.10\\x64\\python3.exe",
                    "C:\\work\\fake-opencode",
                ],
            )
            os.environ["HH_OPENCODE"] = "opencode"
            self.assertEqual(runner._resolve_executable(), ["opencode"])
        finally:
            if old is None:
                os.environ.pop("HH_OPENCODE", None)
            else:
                os.environ["HH_OPENCODE"] = old


if __name__ == "__main__":
    unittest.main()
