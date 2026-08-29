"""Tests for scripts/deps/run-pipelines.sh (tier 3 manual pipeline runner).

These tests only exercise argument parsing (``--help``, unknown arguments,
missing required arguments) and the presence/shape of the companion recipe
manifest. Full execution fetches live SRA reads and runs TaxTriage/EsViritu,
which needs network access and multi-GB databases, so it is deliberately not
exercised here; see docs/release/dependency-sweep.md for the manual sweep
procedure.
"""

import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "deps" / "run-pipelines.sh"
PIPELINE_GOLDENS = ROOT / "scripts" / "deps" / "pipeline-goldens.json"
DIFF_GOLDENS = ROOT / "scripts" / "deps" / "diff_goldens.py"
DEFAULT_ACCESSION = "SRR35517702"


def run_script(args):
    return subprocess.run(
        ["/bin/bash", str(SCRIPT), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


class RunPipelinesScriptTests(unittest.TestCase):
    def test_script_exists_and_is_executable(self):
        self.assertTrue(SCRIPT.is_file())

    def test_bash_syntax_is_valid(self):
        result = subprocess.run(
            ["/bin/bash", "-n", str(SCRIPT)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_help_exits_zero_and_prints_usage(self):
        result = run_script(["--help"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("run-pipelines.sh --which", result.stdout)
        self.assertIn("taxtriage|esviritu|all", result.stdout)
        self.assertIn("tier3-report.md", result.stdout)

    def test_short_help_flag_also_exits_zero(self):
        result = run_script(["-h"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("usage:", result.stdout)

    def test_unknown_argument_exits_64(self):
        result = run_script(["--bogus-flag"])
        self.assertEqual(result.returncode, 64)
        self.assertIn("unknown argument", result.stderr)

    def test_missing_required_arguments_exits_64(self):
        result = run_script([])
        self.assertEqual(result.returncode, 64)
        self.assertIn("--which and --out are required", result.stderr)

    def test_invalid_which_value_exits_64(self):
        result = run_script(["--which", "bogus", "--out", "/tmp/does-not-matter"])
        self.assertEqual(result.returncode, 64)
        self.assertIn("--which must be one of", result.stderr)

    def test_default_database_discovery_uses_installer_directory_names(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("for candidate in kraken2-viral kraken2-standard-16", source)


class CollectAndExitPathTests(unittest.TestCase):
    """The collect/diff/exit tail, driven with fake candidate directories.

    The full script fetches live SRA reads and runs TaxTriage/EsViritu, so
    these tests exercise the two decision points that previously let a broken
    run exit 0: ``collect_output`` finding nothing, and ``diff_goldens.py``
    reporting a missing file (exit 3).
    """

    def _extract_collect_output(self):
        """The `collect_output` function body, lifted from the script."""
        source = SCRIPT.read_text(encoding="utf-8")
        start = source.index("collect_output() {")
        end = source.index("\n}\n", start) + len("\n}\n")
        return source[start:end]

    def _run_collect(self, script_body):
        with tempfile.TemporaryDirectory() as tmp:
            harness = (
                "set -uo pipefail\n"
                f'diff_candidate_dir="{tmp}/candidate"\n'
                'mkdir -p "$diff_candidate_dir"\n'
                "collect_failures=0\n"
                + self._extract_collect_output()
                + "\n"
                + script_body
                + '\necho "COLLECT_FAILURES=${collect_failures}"\n'
            )
            return subprocess.run(
                ["/bin/bash", "-c", harness],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=30,
            ), tmp

    def test_collect_output_counts_a_failure_when_nothing_matches(self):
        result, _ = self._run_collect(
            'collect_output some-recipe out.tsv /nonexistent/a.tsv /nonexistent/b.tsv || true'
        )
        self.assertIn("COLLECT_FAILURES=1", result.stdout)
        self.assertIn("no output matched", result.stderr)

    def test_collect_output_succeeds_and_copies_the_first_existing_candidate(self):
        with tempfile.TemporaryDirectory() as src:
            present = pathlib.Path(src) / "present.tsv"
            present.write_text("a\tb\n", encoding="utf-8")
            result, candidate_root = self._run_collect(
                f'collect_output some-recipe out.tsv /nonexistent/a.tsv "{present}"'
            )
        self.assertIn("COLLECT_FAILURES=0", result.stdout)
        self.assertIn("collected some-recipe/out.tsv", result.stdout)

    def test_diff_goldens_reports_exit_3_for_a_missing_candidate_output(self):
        # This is the status the runner used to treat as "not drift, so fine".
        with tempfile.TemporaryDirectory() as tmp:
            candidate = pathlib.Path(tmp) / "candidate"
            candidate.mkdir()
            result = subprocess.run(
                [
                    "python3",
                    str(DIFF_GOLDENS),
                    "--recipes",
                    str(PIPELINE_GOLDENS),
                    "--candidate",
                    str(candidate),
                    "--set",
                    "tier3-test",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=60,
            )
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)

    def test_script_treats_diff_exit_3_and_collect_failures_as_failures(self):
        source = SCRIPT.read_text(encoding="utf-8")
        # An empty candidate directory must not be able to produce exit 0.
        self.assertIn("if [[ ${collect_failures} -gt 0 ]]; then\n    exit 1", source)
        self.assertIn("if [[ ${diff_status} -ne 0 ]]; then\n    exit 1", source)

    def test_no_executable_line_swallows_a_copy_failure(self):
        # Comments may still describe the old `cp ... 2>/dev/null || true`
        # form, so this looks only at executable lines.
        offenders = [
            line
            for line in SCRIPT.read_text(encoding="utf-8").splitlines()
            if not line.lstrip().startswith("#") and "2>/dev/null" in line
        ]
        self.assertEqual(offenders, [])


class PipelineGoldensManifestTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(PIPELINE_GOLDENS.read_text(encoding="utf-8"))

    def test_manifest_has_goldens_list(self):
        self.assertIn("goldens", self.manifest)
        self.assertTrue(self.manifest["goldens"])

    def test_every_recipe_uses_header_only_tsv_diff(self):
        for recipe in self.manifest["goldens"]:
            for name, spec in recipe["outputs"].items():
                self.assertEqual(
                    spec.get("kind"),
                    "tsv-header",
                    f"{recipe['id']}/{name} must use kind 'tsv-header' for schema-only diffing",
                )
                self.assertEqual(
                    spec.get("compareColumns"),
                    [],
                    f"{recipe['id']}/{name} must set compareColumns: [] (headers only)",
                )

    def test_every_golden_directory_exists(self):
        for recipe in self.manifest["goldens"]:
            golden_dir = ROOT / recipe["golden"]
            self.assertTrue(
                golden_dir.is_dir(), f"{recipe['id']}: golden directory missing: {golden_dir}"
            )

    def test_every_golden_file_exists(self):
        # Output names carry a {sample} placeholder that run-pipelines.sh
        # resolves from --accession; the committed mini fixtures are named for
        # the default accession, so that is what this check resolves against.
        for recipe in self.manifest["goldens"]:
            golden_dir = ROOT / recipe["golden"]
            for name in recipe["outputs"]:
                golden_file = golden_dir / name.replace("{sample}", DEFAULT_ACCESSION)
                self.assertTrue(
                    golden_file.is_file(),
                    f"{recipe['id']}: golden file missing: {golden_file}",
                )

    def test_sample_named_outputs_use_the_placeholder_not_a_hardcoded_accession(self):
        # A hardcoded accession here would make every non-default sweep report
        # its outputs missing while the runner still exited 0.
        for recipe in self.manifest["goldens"]:
            for name in recipe["outputs"]:
                self.assertNotIn(
                    DEFAULT_ACCESSION,
                    name,
                    f"{recipe['id']}: output {name!r} hardcodes the default accession; "
                    "use the {sample} placeholder instead",
                )

    def test_taxtriage_and_esviritu_both_represented(self):
        tools = {recipe["tool"] for recipe in self.manifest["goldens"]}
        self.assertIn("taxtriage", tools)
        self.assertIn("esviritu", tools)


class StorageRootTests(unittest.TestCase):
    """The isolated storage root must reach the CLI invocations.

    The CLI resolves its tools and databases from the managed storage root, so a
    tier 3 run that does not carry the sweep's isolated root reports on the
    developer's real ~/.lungfish instead: the pipelines would exercise tools and
    databases the sweep never provisioned, while the run claims to measure the
    isolated set.

    These use --dry-run, which resolves everything and prints it without fetching
    reads or running a pipeline.
    """

    def dry_run(self, args, env=None):
        import os

        merged = dict(os.environ)
        # Cleared so a developer's own exported root cannot make a test that
        # checks the default path pass for the wrong reason.
        merged.pop("LUNGFISH_STORAGE_ROOT", None)
        merged.pop("LUNGFISH_CONDA_ROOT", None)
        if env:
            merged.update(env)
        with tempfile.TemporaryDirectory() as out:
            return subprocess.run(
                ["/bin/bash", str(SCRIPT), "--which", "all", "--out", out, "--dry-run", *args],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                env=merged,
            )

    def test_dry_run_exits_zero_without_running_anything(self):
        result = self.dry_run(["--root", "/tmp/lungfish-verify-test"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("nothing will be fetched or executed", result.stdout)

    def test_root_flag_reaches_the_environment_and_both_pipelines(self):
        # The script realpaths the root, and on macOS /tmp is a symlink to
        # /private/tmp, so the expectation is realpathed the same way.
        import os

        root = os.path.realpath("/tmp/lungfish-verify-test")
        result = self.dry_run(["--root", "/tmp/lungfish-verify-test"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        self.assertIn(f"LUNGFISH_STORAGE_ROOT={root}", result.stdout)
        # The conda root the read-fetch and subsample steps resolve from must come
        # from the same place, or the reads are prepared with the wrong seqkit.
        self.assertIn(f"conda root={root}/conda", result.stdout)
        self.assertIn(f"{root}/conda/envs/sra-tools/bin", result.stdout)
        self.assertIn(f"{root}/conda/envs/seqkit/bin", result.stdout)
        # Both CLI pipelines are listed, and they inherit the exported root.
        self.assertIn("taxtriage run", result.stdout)
        self.assertIn("esviritu detect", result.stdout)

    def test_root_defaults_to_the_exported_storage_root(self):
        import os

        root = os.path.realpath("/tmp/lungfish-verify-exported")
        result = self.dry_run([], env={"LUNGFISH_STORAGE_ROOT": "/tmp/lungfish-verify-exported"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"LUNGFISH_STORAGE_ROOT={root}", result.stdout)
        self.assertIn(f"conda root={root}/conda", result.stdout)

    def test_root_flag_wins_over_the_exported_storage_root(self):
        result = self.dry_run(
            ["--root", "/tmp/lungfish-verify-flag"],
            env={"LUNGFISH_STORAGE_ROOT": "/tmp/lungfish-verify-exported"},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        import os

        self.assertIn(
            "LUNGFISH_STORAGE_ROOT=" + os.path.realpath("/tmp/lungfish-verify-flag"),
            result.stdout,
        )
        self.assertNotIn("lungfish-verify-exported", result.stdout)

    def test_no_root_leaves_the_cli_default_in_place(self):
        result = self.dry_run([])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("<unset, CLI default>", result.stdout)

    def test_root_requires_a_value(self):
        result = run_script(["--which", "all", "--out", "/tmp/x", "--root"])
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("--root requires a value", result.stderr)

    def test_verify_script_passes_its_isolated_root_to_this_runner(self):
        # The two scripts have to agree, or a sweep's tier 3 silently measures a
        # different root than tiers 1 and 2 did.
        verify = (ROOT / "scripts" / "deps" / "verify.sh").read_text(encoding="utf-8")
        runner = re.search(
            r"run-pipelines\.sh(.*?)\n\s*\}", verify, re.DOTALL
        )
        self.assertIsNotNone(runner, "run-pipelines.sh invocation not found in verify.sh")
        self.assertIn("--root", runner.group(1))


if __name__ == "__main__":
    unittest.main()
