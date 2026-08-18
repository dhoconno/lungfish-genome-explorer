"""Tests for scripts/deps/run-pipelines.sh (tier 3 manual pipeline runner).

These tests only exercise argument parsing (``--help``, unknown arguments,
missing required arguments) and the presence/shape of the companion recipe
manifest. Full execution fetches live SRA reads and runs TaxTriage/EsViritu,
which needs network access and multi-GB databases, so it is deliberately not
exercised here; see docs/release/dependency-sweep.md for the manual sweep
procedure.
"""

import json
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "deps" / "run-pipelines.sh"
PIPELINE_GOLDENS = ROOT / "scripts" / "deps" / "pipeline-goldens.json"


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
        for recipe in self.manifest["goldens"]:
            golden_dir = ROOT / recipe["golden"]
            for name in recipe["outputs"]:
                golden_file = golden_dir / name
                self.assertTrue(
                    golden_file.is_file(),
                    f"{recipe['id']}: golden file missing: {golden_file}",
                )

    def test_taxtriage_and_esviritu_both_represented(self):
        tools = {recipe["tool"] for recipe in self.manifest["goldens"]}
        self.assertIn("taxtriage", tools)
        self.assertIn("esviritu", tools)


if __name__ == "__main__":
    unittest.main()
