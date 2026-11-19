import fnmatch
import json
import os
import subprocess
import sys
import tempfile
import unittest

from lib import guard


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT, "lib", "guard.py")


class PathFormsTest(unittest.TestCase):
    def test_windows_spellings_match_and_linux_has_no_drive_forms(self):
        spellings = ("C:/work/proj", "C:\\work\\proj", "/c/work/proj")
        sets = [set(guard.path_forms(value)) for value in spellings]
        self.assertEqual(sets[0], sets[1])
        self.assertEqual(sets[1], sets[2])
        linux = guard.path_forms("/home/test/proj")
        for form in linux:
            self.assertFalse(form.startswith("C:"), form)
            self.assertNotRegex(form, r"^/[A-Za-z]/")


class VariantsTest(unittest.TestCase):
    def test_relative_glob_has_bare_rooted_and_globstar_forms(self):
        values = guard.variants("secrets/**", "C:/work/proj")
        self.assertIn("secrets/**", values)
        self.assertIn("C:/work/proj/secrets/**", values)
        self.assertIn("**/secrets/**", values)
        self.assertEqual(len(values), len(set(values)))


class ConfigTest(unittest.TestCase):
    def _resources(self, config, action):
        return [
            rule["resource"]
            for rule in config["permissions"]
            if rule["action"] == action
        ]

    def test_config_denies_read_and_glob_for_every_root_spelling(self):
        cases = [
            ("C:/work/proj", "C:/work/proj/secrets/app.key"),
            ("C:\\work\\proj", "C:\\work\\proj\\secrets\\app.key"),
            ("/c/work/proj", "/c/work/proj/secrets/app.key"),
        ]
        for root, path in cases:
            config = guard.make_config(["secrets/**"], root)
            for action in ("read", "glob"):
                resources = self._resources(config, action)
                self.assertTrue(
                    any(fnmatch.fnmatchcase(path, item) for item in resources),
                    (root, action, path),
                )

    def test_config_matches_case_insensitive_windows_roots(self):
        config = guard.make_config(["C:/Work/Secrets/**"], "C:/work/proj")
        resources = self._resources(config, "read")
        self.assertTrue(
            any(
                fnmatch.fnmatchcase("c:/work/secrets/app.key", item)
                for item in resources
            )
        )

    def test_config_allows_source_file(self):
        config = guard.make_config(["secrets/**"], "C:/work/proj")
        for action in ("read", "glob"):
            resources = self._resources(config, action)
            self.assertFalse(
                any(
                    fnmatch.fnmatchcase("C:/work/proj/src/main.py", item)
                    for item in resources
                )
            )

    def test_every_deny_all_action_has_one_rule(self):
        config = guard.make_config(["secrets/**"], "C:/work/proj")
        for action in guard.DENY_ALL_ACTIONS:
            hits = [
                rule
                for rule in config["permissions"]
                if rule["action"] == action and rule["resource"] == "*"
            ]
            self.assertEqual(len(hits), 1, action)
            self.assertEqual(hits[0]["effect"], "deny")

    def test_no_duplicate_pairs(self):
        config = guard.make_config(["secrets/**", "**/*.key"], "C:/work/proj")
        pairs = [(rule["action"], rule["resource"]) for rule in config["permissions"]]
        self.assertEqual(len(pairs), len(set(pairs)))


class MentionTest(unittest.TestCase):
    def test_mentions_finds_absolute_and_relative_paths(self):
        text = r"Read C:\work\proj\secrets\app.key then secrets/db.sqlite3 now"
        hits = guard.scan_mentions(text, ["secrets/**"], "C:/work/proj")
        self.assertIn(r"C:\work\proj\secrets\app.key", hits)
        self.assertIn("secrets/db.sqlite3", hits)

    def test_mentions_ignores_quoted_glob(self):
        text = "The guard excludes secrets/** from this run."
        self.assertEqual(guard.scan_mentions(text, ["secrets/**"], "C:/work/proj"), [])


class CliTest(unittest.TestCase):
    def test_config_writes_valid_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "guard.json")
            result = subprocess.run(
                [sys.executable, GUARD, "config", target, "C:/work/proj", "secrets/**"],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            with open(target, encoding="utf-8") as handle:
                document = json.load(handle)
            self.assertIn("permissions", document)

    def test_no_arguments_exits_two(self):
        result = subprocess.run([sys.executable, GUARD], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
