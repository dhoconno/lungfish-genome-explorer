"""Argument-parsing and plan-printing tests for scripts/deps/verify.sh.

These tests only exercise argument handling and the dry-run plan line, so they
never build, never invoke swift, and never touch conda environments or
databases. Everything past the dry-run exit is covered by actually running a
sweep, not by unit tests.
"""

import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
VERIFY = ROOT / "scripts" / "deps" / "verify.sh"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
MANIFEST = ROOT / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"

# Generous enough for a cold python/bash start on a loaded machine, but far
# below the runtime of any real work the script could otherwise start.
TIMEOUT_SECONDS = 60


def run_verify(args):
    return subprocess.run(
        ["/bin/bash", str(VERIFY), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=TIMEOUT_SECONDS,
        cwd=str(ROOT),
    )


class BashSyntaxTests(unittest.TestCase):
    def test_script_parses(self):
        result = subprocess.run(
            ["/bin/bash", "-n", str(VERIFY)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


class DryRunTests(unittest.TestCase):
    def test_dry_run_prints_the_resolved_plan_line(self):
        result = run_verify(["--tier", "1", "--dry-run", "--root", "/tmp/lungfish-verify-test"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("verify: set=", result.stdout)
        self.assertIn("manifest=", result.stdout)
        self.assertIn("root=/tmp/lungfish-verify-test", result.stdout)
        self.assertIn("tier=1", result.stdout)

    def test_dry_run_reports_the_manifest_dependency_set(self):
        import json

        expected = json.loads(MANIFEST.read_text(encoding="utf-8"))["dependencySet"]
        result = run_verify(["--dry-run", "--root", "/tmp/lungfish-verify-test"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"set={expected}", result.stdout)

    def test_dry_run_reports_the_manifest_sha256(self):
        digest = subprocess.run(
            ["shasum", "-a", "256", str(MANIFEST)],
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout.split()[0]
        result = run_verify(["--dry-run", "--root", "/tmp/lungfish-verify-test"])
        self.assertIn(f"manifest={digest}", result.stdout)

    def test_dry_run_does_not_provision_anything(self):
        result = run_verify(["--dry-run", "--root", "/tmp/lungfish-verify-test"])
        combined = result.stdout + result.stderr
        self.assertNotIn("Building lungfish-cli", combined)
        self.assertNotIn("Provisioning", combined)

    def test_tier_defaults_to_one(self):
        result = run_verify(["--dry-run", "--root", "/tmp/lungfish-verify-test"])
        self.assertIn("tier=1", result.stdout)


class ArgumentGuardTests(unittest.TestCase):
    VALUE_FLAGS = ("--tier", "--root", "--seed-from", "--filter")

    def test_every_value_flag_without_a_value_exits_64(self):
        for flag in self.VALUE_FLAGS:
            with self.subTest(flag=flag):
                result = run_verify([flag])
                self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
                self.assertIn(f"{flag} requires a value", result.stderr)

    def test_trailing_value_flag_after_valid_flags_exits_64(self):
        result = run_verify(["--tier", "1", "--root"])
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("--root requires a value", result.stderr)

    def test_unknown_flag_exits_64(self):
        result = run_verify(["--bogus"])
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("unknown argument", result.stderr)

    def test_bad_tier_exits_64(self):
        # The tier is validated before any provisioning work, so a typo fails
        # immediately rather than after twenty minutes of downloads. This runs
        # without --dry-run precisely to prove the validation happens first.
        result = run_verify(["--tier", "9", "--root", "/tmp/lungfish-verify-test"])
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("--tier must be one of", result.stderr)

    def test_help_exits_zero_and_describes_the_tiers(self):
        result = run_verify(["--help"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--tier", result.stdout)
        self.assertIn("--seed-from", result.stdout)

    def test_root_may_not_be_the_real_managed_storage_root(self):
        # Provisioning reinstalls environments to match the manifest, so
        # pointing verify at ~/.lungfish would rewrite the developer's own
        # 21 GB conda root. Refuse before doing any work.
        result = run_verify(["--tier", "1", "--root", str(pathlib.Path.home() / ".lungfish")])
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("must not be the real managed storage root", result.stderr)


class FilterSyncTests(unittest.TestCase):
    def test_tier1_default_filter_matches_the_ci_job_filter(self):
        """verify.sh tier 1 and the CI conformance job must run the same suites.

        If they drift, a local sweep can pass while CI fails (or the reverse),
        and the sweep's "tier 1 is green" claim stops meaning what it says.
        """
        script = VERIFY.read_text(encoding="utf-8")
        script_filter = re.search(
            r"^default_tier1_filter='([^']*)'", script, re.MULTILINE
        )
        self.assertIsNotNone(script_filter, "default_tier1_filter not found in verify.sh")

        workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        ci_filter = re.search(
            r"full-suite-gate\.sh --require-tools --filter '([^']*)'", workflow
        )
        self.assertIsNotNone(ci_filter, "conformance filter not found in ci.yml")

        self.assertEqual(script_filter.group(1), ci_filter.group(1))

    def test_conformance_packs_match_the_ci_job(self):
        script = VERIFY.read_text(encoding="utf-8")
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        packs = re.search(
            r"^conformance_packs=\(\n(.*?)\n\)", script, re.MULTILINE | re.DOTALL
        )
        self.assertIsNotNone(packs, "conformance_packs not found in verify.sh")
        for pack in packs.group(1).split():
            with self.subTest(pack=pack):
                self.assertIn(f"conda install --pack {pack}", workflow)


if __name__ == "__main__":
    unittest.main()
