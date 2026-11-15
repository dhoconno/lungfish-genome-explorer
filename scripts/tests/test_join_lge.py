"""Tests for scripts/repro/rnaseq/tenx-controls/join_lge.py (RS-SC-IMPORT, review BIO SF2).

Run from the repository root:
    python3 -m unittest discover -s scripts/tests -p 'test_join_lge.py' -v

join_lge.py joins WORK/lge/RUN/SET.tsv, which compare_lge.py wrote from two LGE results, to WORK/compare/SET.tsv,
which compare.py wrote from the tools' own matrices. LGE's import of one tool set against its import of the other
cannot show a count that is wrong on both sides, so a row that differs must end the join with exit status 1.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "repro" / "rnaseq" / "tenx-controls" / "join_lge.py"
HEADER = "set\trun\tmeasure\tours\ttenx\tnote\n"
RUN = "STARsolo_Gene"


def table(rows):
    return HEADER + "".join("s\t%s\t%s\t%s\t%s\t\n" % (RUN, m, o, t) for m, o, t in rows)


class JoinLgeCase(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="test_join_lge_"))
        self.addCleanup(shutil.rmtree, self.work, ignore_errors=True)
        (self.work / "compare").mkdir()

    def put(self, name, lge_rows, compare_rows, run="RS-SC-IMPORT"):
        (self.work / "lge" / run).mkdir(parents=True, exist_ok=True)
        (self.work / "lge" / run / (name + ".tsv")).write_text(table(lge_rows))
        (self.work / "compare" / (name + ".tsv")).write_text(table(compare_rows))

    def join(self, *sets, run=None):
        env = {k: v for k, v in os.environ.items() if k != "LGE_RUN"}
        if run is not None:
            env["LGE_RUN"] = run
        return subprocess.run([sys.executable, "-I", str(SCRIPT), str(self.work), *sets], env=env, capture_output=True, text=True)

    def test_equal_rows_join_and_exit_zero(self):
        rows = [("cells_called", "200", "200"), ("median_umi_per_cell", "5000", "5000"), ("summary:Number of Reads", "100", "100")]
        self.put("s", rows, rows)
        done = self.join("s")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("rows unequal: 0", done.stdout)
        self.assertEqual(done.stdout.count("| yes |"), 3)

    def test_a_wrong_count_exits_one_and_marks_the_row(self):
        self.put("s", [("cells_called", "199", "200"), ("median_umi_per_cell", "5000", "5000")],
                 [("cells_called", "200", "200"), ("median_umi_per_cell", "5000", "5000")])
        done = self.join("s")
        self.assertEqual(done.returncode, 1)
        self.assertIn("| s | STARsolo_Gene | cells_called | 199 | 200 | NO |", done.stdout)
        self.assertIn("rows unequal: 1", done.stdout)

    def test_a_row_compare_py_lacks_is_unequal(self):
        self.put("s", [("cells_called", "200", "200"), ("total_genes_detected", "900", "900")], [("cells_called", "200", "200")])
        done = self.join("s")
        self.assertEqual(done.returncode, 1)
        self.assertIn("| total_genes_detected | 900 | none | NO |", done.stdout)

    def test_rows_with_no_twin_print_and_never_fail(self):
        lge = [("cells_called", "200", "200"), ("gene_total_pearson_log1p_ge10_own_cells", "0.99970", "1.00000"), ("genes_dropped_by_alignment", "0", "0")]
        ref = [("cells_called", "200", "200"), ("gene_total_pearson_log1p_ge10", "0.99971", "1.00000")]
        self.put("s", lge, ref)
        done = self.join("s")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("| 0.99970 | 0.99971 (shared cells) | beside |", done.stdout)
        self.assertIn("| genes_dropped_by_alignment | 0 | none | info |", done.stdout)

    def test_the_run_folder_comes_from_LGE_RUN(self):
        rows = [("cells_called", "200", "200")]
        self.put("s", rows, rows, run="FIX")
        self.assertEqual(self.join("s", run="FIX").returncode, 0)
        self.assertEqual(self.join("s").returncode, 1, "the default run folder RS-SC-IMPORT holds no table")
        self.assertEqual(self.join("s", run="").returncode, 1, "an empty LGE_RUN reads as the default, as the shell does")

    def test_every_set_is_joined_and_one_wrong_set_fails_the_join(self):
        rows = [("cells_called", "200", "200")]
        self.put("a", rows, rows)
        self.put("b", [("cells_called", "201", "200")], rows)
        done = self.join("a", "b")
        self.assertEqual(done.returncode, 1)
        self.assertIn("| a | STARsolo_Gene | cells_called | 200 | 200 | yes |", done.stdout)
        self.assertIn("| b | STARsolo_Gene | cells_called | 201 | 200 | NO |", done.stdout)

    def test_a_table_with_nothing_to_compare_fails(self):
        self.put("s", [], [("cells_called", "200", "200")])
        self.assertEqual(self.join("s").returncode, 1)

    def test_a_missing_table_fails_in_words(self):
        done = self.join("s")
        self.assertEqual(done.returncode, 1)
        self.assertIn("is missing, so the counts of s are not checked", done.stderr)


if __name__ == "__main__":
    unittest.main()
