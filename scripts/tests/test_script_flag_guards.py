"""Argument-guard tests for the regression-tier shell scripts.

Every value-taking flag in these scripts must reject a missing value with exit
64 (EX_USAGE) *promptly*, rather than shifting past the end of the argument
list. Under ``set -u`` a bare ``shift 2`` with one argument left aborts the
script, and without ``set -u`` (full-suite-gate.sh uses ``set -u`` but its
loop consumed the flag either way) an empty value silently became "run
everything", which for the gate means launching the entire multi-hour suite
when the caller asked for a filtered run and simply forgot the pattern.

These tests only exercise argument parsing, so they never build, never invoke
swift, and never touch conda environments or databases.
"""

import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "full-suite-gate.sh"
REGENERATE = ROOT / "scripts" / "deps" / "regenerate-goldens.sh"
RUN_PIPELINES = ROOT / "scripts" / "deps" / "run-pipelines.sh"

# Generous enough for a cold python/bash start on a loaded machine, but far
# below the runtime of any real work these scripts could otherwise start.
TIMEOUT_SECONDS = 30


def run_script(script, args):
    return subprocess.run(
        ["/bin/bash", str(script), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=TIMEOUT_SECONDS,
        cwd=str(ROOT),
    )


class BashSyntaxTests(unittest.TestCase):
    def test_all_three_scripts_parse(self):
        for script in (GATE, REGENERATE, RUN_PIPELINES):
            with self.subTest(script=script.name):
                result = subprocess.run(
                    ["/bin/bash", "-n", str(script)],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)


class FullSuiteGateFlagGuardTests(unittest.TestCase):
    def test_filter_without_value_exits_64_promptly(self):
        result = run_script(GATE, ["--filter"])
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("--filter requires a value", result.stderr)

    def test_filter_without_value_does_not_start_a_test_run(self):
        result = run_script(GATE, ["--filter"])
        combined = result.stdout + result.stderr
        self.assertNotIn("Full-suite gate starting", combined)

    def test_unknown_argument_still_exits_64(self):
        result = run_script(GATE, ["--bogus"])
        self.assertEqual(result.returncode, 64)
        self.assertIn("unknown argument", result.stderr)


class RegenerateGoldensFlagGuardTests(unittest.TestCase):
    VALUE_FLAGS = ("--set", "--out", "--only", "--recipes")

    def test_every_value_flag_without_a_value_exits_64(self):
        for flag in self.VALUE_FLAGS:
            with self.subTest(flag=flag):
                result = run_script(REGENERATE, [flag])
                self.assertEqual(
                    result.returncode, 64, result.stdout + result.stderr
                )
                self.assertIn(f"{flag} requires a value", result.stderr)

    def test_trailing_value_flag_after_valid_flags_exits_64(self):
        result = run_script(REGENERATE, ["--set", "2026.1", "--out"])
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("--out requires a value", result.stderr)


class RunPipelinesFlagGuardTests(unittest.TestCase):
    VALUE_FLAGS = ("--which", "--out", "--accession", "--cli")

    def test_every_value_flag_without_a_value_exits_64(self):
        for flag in self.VALUE_FLAGS:
            with self.subTest(flag=flag):
                result = run_script(RUN_PIPELINES, [flag])
                self.assertEqual(
                    result.returncode, 64, result.stdout + result.stderr
                )
                self.assertIn(f"{flag} requires a value", result.stderr)

    def test_trailing_value_flag_after_valid_flags_exits_64(self):
        result = run_script(RUN_PIPELINES, ["--which", "all", "--out"])
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("--out requires a value", result.stderr)


if __name__ == "__main__":
    unittest.main()
