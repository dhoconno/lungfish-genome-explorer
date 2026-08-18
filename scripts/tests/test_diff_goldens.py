"""Tests for scripts/deps/diff_goldens.py and the golden recipe manifest."""

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/deps"))

import diff_goldens  # noqa: E402

DIFF_SCRIPT = ROOT / "scripts" / "deps" / "diff_goldens.py"
RECIPES = ROOT / "scripts" / "deps" / "goldens.json"
CURRENT_SET = "2026.1"


class DiffGoldensTests(unittest.TestCase):
    def test_text_exact_comparison(self):
        self.assertEqual(diff_goldens.compare_text("5\n", "5\n", {}), [])
        self.assertNotEqual(diff_goldens.compare_text("5\n", "6\n", {}), [])

    def test_tsv_header_change_is_failure(self):
        g = "a\tb\n1\t2\n"
        c = "a\tb\tc\n1\t2\t3\n"
        diffs = diff_goldens.compare_tsv_header(g, c, {"compareColumns": ["a", "b"]})
        self.assertTrue(any("header" in d for d in diffs), diffs)

    def test_tsv_header_same_header_same_values_is_clean(self):
        g = "num_seqs\tsum_len\n10\t100\n"
        c = "num_seqs\tsum_len\n10\t100\n"
        self.assertEqual(
            diff_goldens.compare_tsv_header(g, c, {"compareColumns": ["num_seqs", "sum_len"]}),
            [],
        )

    def test_tsv_header_relative_tolerance_on_numbers(self):
        g = "num_seqs\tsum_len\n100\t1000\n"
        c = "num_seqs\tsum_len\n102\t1000\n"
        spec = {"compareColumns": ["num_seqs", "sum_len"], "numericTolerance": 0.05, "relative": True}
        self.assertEqual(diff_goldens.compare_tsv_header(g, c, spec), [])
        tight = {"compareColumns": ["num_seqs", "sum_len"], "numericTolerance": 0.001, "relative": True}
        self.assertNotEqual(diff_goldens.compare_tsv_header(g, c, tight), [])

    def test_tsv_positional_keys_and_columns(self):
        g = "chr1\t100\t5\t0\nchr2\t200\t7\t0\n"
        c = "chr1\t100\t5\t0\nchr2\t200\t9\t0\n"
        spec = {"keyColumns": [0], "compareColumns": [1, 2, 3]}
        diffs = diff_goldens.compare_tsv(g, c, spec)
        self.assertTrue(any("chr2" in d for d in diffs), diffs)
        self.assertEqual(diff_goldens.compare_tsv(g, g, spec), [])

    def test_tsv_reports_missing_and_extra_rows(self):
        g = "chr1\t1\nchr2\t2\n"
        c = "chr1\t1\nchr3\t3\n"
        spec = {"keyColumns": [0], "compareColumns": [1]}
        diffs = diff_goldens.compare_tsv(g, c, spec)
        self.assertTrue(any("chr2" in d for d in diffs), diffs)
        self.assertTrue(any("chr3" in d for d in diffs), diffs)

    def test_json_relative_tolerance(self):
        g = {"x": 100, "y": {"z": 1.0}}
        c = {"x": 101, "y": {"z": 1.0}}
        self.assertEqual(diff_goldens.compare_json(g, c, {"numericTolerance": 0.02, "relative": True}), [])
        self.assertNotEqual(diff_goldens.compare_json(g, c, {"numericTolerance": 0.001, "relative": True}), [])

    def test_json_absolute_tolerance_default_is_exact(self):
        self.assertEqual(diff_goldens.compare_json({"x": 3}, {"x": 3}, {}), [])
        self.assertNotEqual(diff_goldens.compare_json({"x": 3}, {"x": 4}, {}), [])

    def test_json_ignore_keys(self):
        g = {"time": 1.0, "reads": 10}
        c = {"time": 99.0, "reads": 10}
        self.assertEqual(diff_goldens.compare_json(g, c, {"ignoreKeys": ["time"]}), [])

    def test_json_accepts_raw_text(self):
        self.assertEqual(diff_goldens.compare_json('{"a": 1}', '{"a": 1}', {}), [])
        self.assertNotEqual(diff_goldens.compare_json('{"a": 1}', '{"a": 2}', {}), [])

    def test_json_structural_differences(self):
        diffs = diff_goldens.compare_json({"a": 1}, {"b": 1}, {})
        self.assertTrue(diffs)
        diffs = diff_goldens.compare_json({"a": [1, 2]}, {"a": [1, 2, 3]}, {})
        self.assertTrue(diffs)

    def test_kreport_rank_set_and_counts(self):
        g = " 50.00\t5\t5\tU\t0\tunclassified\n 50.00\t5\t0\tR\t1\troot\n"
        c = (
            " 50.00\t5\t5\tU\t0\tunclassified\n"
            " 50.00\t5\t0\tR\t1\troot\n"
            "  10.00\t1\t1\tD\t2\t  Viruses\n"
        )
        diffs = diff_goldens.compare_kreport(g, c, {})
        self.assertTrue(any("Viruses" in d for d in diffs), diffs)

    def test_kreport_same_content_is_clean(self):
        g = " 50.00\t5\t5\tU\t0\tunclassified\n 50.00\t5\t0\tR\t1\troot\n"
        self.assertEqual(diff_goldens.compare_kreport(g, g, {}), [])

    def test_kreport_read_count_change_is_a_difference(self):
        g = " 50.00\t5\t5\tU\t0\tunclassified\n"
        c = " 50.00\t7\t7\tU\t0\tunclassified\n"
        diffs = diff_goldens.compare_kreport(g, c, {})
        self.assertTrue(diffs)

    def test_kreport_parses_eight_column_rows(self):
        g = " 50.00\t5\t5\t50\t0\tU\t0\tunclassified\n"
        c = " 50.00\t5\t5\t50\t0\tU\t0\tunclassified\n"
        self.assertEqual(diff_goldens.compare_kreport(g, c, {}), [])

    def test_newick_topology_ignores_branch_lengths(self):
        self.assertEqual(diff_goldens.compare_newick("((A:0.1,B:0.2):0.3,C:0.4);", "((A:1,B:1):1,C:1);", {}), [])
        self.assertNotEqual(diff_goldens.compare_newick("((A,B),C);", "((A,C),B);", {}), [])

    def test_newick_topology_ignores_root_placement(self):
        # The same unrooted tree written with two different roots: IQ-TREE emits
        # an unrooted tree, so root placement must not register as a difference.
        self.assertEqual(diff_goldens.compare_newick("((A,B),(C,(D,E)));", "(((A,B),C),(D,E));", {}), [])

    def test_newick_leaf_set_change_is_a_difference(self):
        diffs = diff_goldens.compare_newick("((A,B),C);", "((A,B),D);", {})
        self.assertTrue(any("D" in d or "C" in d for d in diffs), diffs)

    def test_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as td:
            golden = pathlib.Path(td, "g", "x")
            cand = pathlib.Path(td, "c", "x")
            golden.mkdir(parents=True)
            cand.mkdir(parents=True)
            (golden / "count.txt").write_text("5\n")
            (cand / "count.txt").write_text("6\n")
            recipes = {
                "goldens": [
                    {
                        "id": "x",
                        "outputs": {"count.txt": {"kind": "text"}},
                        "golden": "Tests/Fixtures/conformance/{set}/x",
                    }
                ]
            }
            (pathlib.Path(td) / "goldens.json").write_text(json.dumps(recipes))
            r = subprocess.run(
                [
                    sys.executable,
                    str(DIFF_SCRIPT),
                    "--recipes",
                    str(pathlib.Path(td, "goldens.json")),
                    "--golden-root",
                    str(golden.parent),
                    "--candidate",
                    str(cand.parent),
                    "--set",
                    "s",
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(r.returncode, 2, r.stdout + r.stderr)

    def test_cli_exit_zero_when_identical(self):
        with tempfile.TemporaryDirectory() as td:
            golden = pathlib.Path(td, "g", "x")
            cand = pathlib.Path(td, "c", "x")
            golden.mkdir(parents=True)
            cand.mkdir(parents=True)
            (golden / "count.txt").write_text("5\n")
            (cand / "count.txt").write_text("5\n")
            recipes = {"goldens": [{"id": "x", "outputs": {"count.txt": {"kind": "text"}}, "golden": "any/{set}/x"}]}
            (pathlib.Path(td) / "goldens.json").write_text(json.dumps(recipes))
            r = subprocess.run(
                [
                    sys.executable,
                    str(DIFF_SCRIPT),
                    "--recipes",
                    str(pathlib.Path(td, "goldens.json")),
                    "--golden-root",
                    str(golden.parent),
                    "--candidate",
                    str(cand.parent),
                    "--set",
                    "s",
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("same", r.stdout)

    def test_cli_exit_three_when_golden_missing(self):
        with tempfile.TemporaryDirectory() as td:
            golden_root = pathlib.Path(td, "g")
            cand = pathlib.Path(td, "c", "x")
            golden_root.mkdir(parents=True)
            cand.mkdir(parents=True)
            (cand / "count.txt").write_text("5\n")
            recipes = {"goldens": [{"id": "x", "outputs": {"count.txt": {"kind": "text"}}, "golden": "any/{set}/x"}]}
            (pathlib.Path(td) / "goldens.json").write_text(json.dumps(recipes))
            r = subprocess.run(
                [
                    sys.executable,
                    str(DIFF_SCRIPT),
                    "--recipes",
                    str(pathlib.Path(td, "goldens.json")),
                    "--golden-root",
                    str(golden_root),
                    "--candidate",
                    str(cand.parent),
                    "--set",
                    "s",
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(r.returncode, 3, r.stdout + r.stderr)

    def test_cli_only_filter_selects_recipes(self):
        with tempfile.TemporaryDirectory() as td:
            for name, text in (("x", "5\n"), ("y", "5\n")):
                (pathlib.Path(td, "g", name)).mkdir(parents=True)
                (pathlib.Path(td, "c", name)).mkdir(parents=True)
                (pathlib.Path(td, "g", name, "count.txt")).write_text(text)
            (pathlib.Path(td, "c", "x", "count.txt")).write_text("5\n")
            (pathlib.Path(td, "c", "y", "count.txt")).write_text("999\n")
            recipes = {
                "goldens": [
                    {"id": "x", "outputs": {"count.txt": {"kind": "text"}}, "golden": "any/{set}/x"},
                    {"id": "y", "outputs": {"count.txt": {"kind": "text"}}, "golden": "any/{set}/y"},
                ]
            }
            (pathlib.Path(td) / "goldens.json").write_text(json.dumps(recipes))
            r = subprocess.run(
                [
                    sys.executable,
                    str(DIFF_SCRIPT),
                    "--recipes",
                    str(pathlib.Path(td, "goldens.json")),
                    "--golden-root",
                    str(pathlib.Path(td, "g")),
                    "--candidate",
                    str(pathlib.Path(td, "c")),
                    "--set",
                    "s",
                    "--only",
                    "x",
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_cli_json_output_is_parsable(self):
        with tempfile.TemporaryDirectory() as td:
            golden = pathlib.Path(td, "g", "x")
            cand = pathlib.Path(td, "c", "x")
            golden.mkdir(parents=True)
            cand.mkdir(parents=True)
            (golden / "count.txt").write_text("5\n")
            (cand / "count.txt").write_text("6\n")
            recipes = {"goldens": [{"id": "x", "outputs": {"count.txt": {"kind": "text"}}, "golden": "any/{set}/x"}]}
            (pathlib.Path(td) / "goldens.json").write_text(json.dumps(recipes))
            r = subprocess.run(
                [
                    sys.executable,
                    str(DIFF_SCRIPT),
                    "--recipes",
                    str(pathlib.Path(td, "goldens.json")),
                    "--golden-root",
                    str(golden.parent),
                    "--candidate",
                    str(cand.parent),
                    "--set",
                    "s",
                    "--json",
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
            payload = json.loads(r.stdout)
            self.assertEqual(payload["set"], "s")
            self.assertTrue(payload["results"])


class GoldenRecipeManifestTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(RECIPES.read_text(encoding="utf-8"))

    def test_manifest_parses_and_has_recipes(self):
        self.assertIn("goldens", self.manifest)
        self.assertTrue(self.manifest["goldens"])

    def test_recipe_ids_are_unique(self):
        ids = [recipe["id"] for recipe in self.manifest["goldens"]]
        self.assertEqual(len(ids), len(set(ids)))

    def test_every_recipe_has_required_fields(self):
        for recipe in self.manifest["goldens"]:
            for field in ("id", "tool", "env", "inputs", "command", "outputs", "golden"):
                self.assertIn(field, recipe, recipe.get("id"))
            self.assertTrue(recipe["outputs"], recipe["id"])
            for name, spec in recipe["outputs"].items():
                self.assertIn("kind", spec, f"{recipe['id']}:{name}")
                self.assertIn(
                    spec["kind"],
                    {"text", "tsv", "tsv-header", "json", "kreport", "newick-topology"},
                    f"{recipe['id']}:{name}",
                )

    def test_recipe_inputs_exist_in_the_repo(self):
        for recipe in self.manifest["goldens"]:
            for relative in recipe["inputs"]:
                self.assertTrue((ROOT / relative).exists(), f"{recipe['id']}: missing input {relative}")

    def test_every_golden_directory_exists_for_the_current_set(self):
        for recipe in self.manifest["goldens"]:
            golden = ROOT / recipe["golden"].replace("{set}", CURRENT_SET)
            self.assertTrue(golden.is_dir(), f"{recipe['id']}: missing golden dir {golden}")
            for name in recipe["outputs"]:
                self.assertTrue((golden / name).is_file(), f"{recipe['id']}: missing golden output {name}")

    def test_goldens_stay_small(self):
        limit = 200 * 1024
        for recipe in self.manifest["goldens"]:
            golden = ROOT / recipe["golden"].replace("{set}", CURRENT_SET)
            total = sum(p.stat().st_size for p in golden.rglob("*") if p.is_file())
            self.assertLess(total, limit, f"{recipe['id']}: golden dir is {total} bytes")


if __name__ == "__main__":
    unittest.main()
