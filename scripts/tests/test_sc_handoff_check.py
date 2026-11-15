"""Tests for scripts/repro/rnaseq/tenx-controls/sc_handoff_check.py (RS-SC-HANDOFF, slice C).

Run from the repository root:
    python3 -m unittest discover -s scripts/tests -p 'test_sc_handoff_check.py' -v

lge_sc_handoff exports each imported result with the lane's CLI, runs scanpy.py and seurat.R in the export folder and
leaves their output beside it. The check sets what the templates printed and wrote against the numbers in the tools' own
files, against cells.sqlite of the imported result and against each other, so a row that differs must end the check with
exit status 1.
"""
import gzip
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "repro" / "rnaseq" / "tenx-controls" / "sc_handoff_check.py"
RUN = "RS-SC-HANDOFF"
FEATURES = [("G1", "Gene1", "Gene Expression"), ("G2", "Gene2", "Gene Expression"), ("G3", "Gene3", "Gene Expression"),
            ("P1", "Ab1", "Antibody Capture")]
NO_SEURAT = "Error: Seurat is not installed in this R, so the table of cells is written and no Seurat object is made. Install Seurat and run seurat.R again.\nExecution halted\n"


def tsv(rows):
    return "".join("\t".join(str(c) for c in r) + "\n" for r in rows)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


class Fixture:
    """Sets with both sides, every file that the stage leaves for the check, and cells.sqlite of each import."""

    def __init__(self, root):
        self.work, self.data = Path(root) / "work", Path(root) / "data"
        self.lge = self.work / "lge" / RUN

    def export(self, side, name):
        return self.lge / "export" / ("%s-%s" % (side, name))

    def log(self, side, name, kind, ext):
        return self.lge / "export" / ("%s-%s.%s.%s" % (side, name, kind, ext))

    def add(self, name, n=3, estimate=None):
        rows = [("BC%04d-1" % i, 5 + i % 7, 1 + i % 3) for i in range(n)]
        for side in ("solo", "tenx"):
            self.side(side, name, n, rows, estimate if estimate is not None else format(n, ","))

    def side(self, side, name, n, rows, estimate):
        plain, tag = side == "solo", "%s-%s" % (side, name)
        files = {"matrix.mtx": "%%MatrixMarket matrix coordinate integer general\n4 %d 1\n1 1 5\n" % n,
                 "features.tsv": tsv(FEATURES), "barcodes.tsv": "".join(r[0] + "\n" for r in rows)}
        original = self.work / "solo" / name / "Solo.out" / "Gene" / "filtered" if plain else self.lge / "tenx" / name / "outs" / "filtered_feature_bc_matrix"
        folder = self.export(side, name)
        for fname, text in files.items():
            put = original / (fname if plain else fname + ".gz")
            put.parent.mkdir(parents=True, exist_ok=True)
            if plain:
                put.write_text(text)
            else:
                with gzip.GzipFile(put, "wb", mtime=0) as fh:
                    fh.write(text.encode())
            (folder / name).mkdir(parents=True, exist_ok=True)
            shutil.copyfile(put, folder / name / put.name)
        if plain:
            write(self.work / "solo" / name / "Solo.out" / "Gene" / "Summary.csv", "Number of Reads,100\nEstimated Number of Cells,%s\n" % estimate.replace(",", ""))
        else:
            write(self.data / "tenx" / name / ("%s_metrics_summary.csv" % name), 'Estimated Number of Cells,Mean Reads per Cell\n"%s","54,502"\n' % estimate)
        write(folder / "samples.tsv", tsv([("sample_id", "folder", "route"), (name, name, "cells")]))
        write(folder / "genes.tsv", tsv([("gene_id", "gene_name", "not_host")] + [(f[0], f[1], "false") for f in FEATURES]))
        table = tsv([("cell", "sample", "barcode", "umis", "genes")] + [(b, name, b, u, g) for b, u, g in rows])
        write(folder / "scanpy-cells.tsv", table)
        write(folder / "seurat-cells.tsv", table)
        write(self.log(side, name, "seurat-env", "cells.tsv"), table)
        head = "cells %s %d\ncells total %d\nnot-host features 0\n" % (name, n, n)
        logs = {"scanpy": (head + "AnnData object with n_obs × n_vars = %d × 4\n    obs: 'sample', 'barcode'\n" % n, "", 0),
                "seurat-env": (head, NO_SEURAT, 1),
                "seurat": (head + "An object of class Seurat \n4 features across %d samples within 1 assay \nActive assay: RNA (4 features, 0 variable features)\n" % n, "", 0)}
        for kind, (out, err, status) in logs.items():
            write(self.log(side, name, kind, "out"), out)
            write(self.log(side, name, kind, "err"), err)
            write(self.log(side, name, kind, "status"), "%d\n" % status)
        db_path = self.lge / "project.lungfish" / "Analyses" / ("%s.lungfishrnaseq" % tag) / "cells.sqlite"
        db_path.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(db_path)
        db.executescript("CREATE TABLE samples (sample INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, matrix TEXT NOT NULL, cells INTEGER NOT NULL, features INTEGER NOT NULL, entries INTEGER NOT NULL);"
                         'CREATE TABLE cells (cell INTEGER PRIMARY KEY, sample INTEGER NOT NULL, "column" INTEGER NOT NULL, barcode TEXT NOT NULL, umis INTEGER NOT NULL, genes INTEGER NOT NULL);')
        db.execute("INSERT INTO samples VALUES (1, ?, 'source/x', ?, 4, 1)", (name, n))
        db.executemany("INSERT INTO cells VALUES (?, 1, ?, ?, ?, ?)", [(i + 1, i + 1, b, u, g) for i, (b, u, g) in enumerate(rows)])
        db.commit()
        db.close()


def run_check(fx, *sets, run=None):
    env = {k: v for k, v in os.environ.items() if k != "LGE_RUN"}
    if run is not None:
        env["LGE_RUN"] = run
    return subprocess.run([sys.executable, "-I", str(SCRIPT), str(fx.work), str(fx.data), *sets], env=env, capture_output=True, text=True)


class ScHandoffCheckCase(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="test_sc_handoff_check_"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.f = Fixture(self.root)
        self.f.add("s")

    def check(self, *sets, run=None):
        return run_check(self.f, *(sets or ("s",)), run=run)

    def test_an_export_that_matches_its_tools_passes(self):
        done = self.check()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("rows unequal: 0", done.stdout)
        self.assertIn("| s | solo | scanpy.py cells total | 3 | 3 | yes |", done.stdout)
        self.assertIn("| s | tenx | seurat.R cells total (env-r-seurat) | 3 | 3 | yes |", done.stdout)
        self.assertIn("| s | solo | matrix files equal to the tool's own | 3 | 3 | yes |", done.stdout)
        self.assertIn("| s | both | cells of STARsolo and of Cell Ranger | 3 | 3 | beside |", done.stdout)

    def test_a_count_that_differs_from_the_tool_summary_fails(self):
        write(self.f.work / "solo" / "s" / "Solo.out" / "Gene" / "Summary.csv", "Estimated Number of Cells,4\n")
        done = self.check()
        self.assertEqual(done.returncode, 1)
        for name in ("scanpy.py cells total", "seurat.R cells total (env)", "seurat.R cells total (env-r-seurat)", "cells.sqlite cells"):
            self.assertIn("| s | solo | %s | 4 | 3 | NO |" % name, done.stdout)
        self.assertIn("| s | tenx | scanpy.py cells total | 3 | 3 | yes |", done.stdout)

    def test_a_thousands_separator_of_the_cell_ranger_summary_is_read(self):
        big = Fixture(self.root / "big")
        big.add("b", n=1222)
        self.assertIn('"1,222"', (big.data / "tenx" / "b" / "b_metrics_summary.csv").read_text())
        done = run_check(big, "b")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("| b | tenx | scanpy.py cells total | 1222 | 1222 | yes |", done.stdout)

    def test_two_tables_that_differ_in_one_cell_fail(self):
        path = self.f.export("solo", "s") / "seurat-cells.tsv"
        path.write_text(path.read_text().replace("\t5\t1\n", "\t6\t1\n", 1))
        done = self.check()
        self.assertEqual(done.returncode, 1)
        self.assertIn("| s | solo | scanpy-cells.tsv vs seurat-cells.tsv, rows that differ | 0 | 1 | NO |", done.stdout)
        self.assertIn("| s | solo | scanpy-cells.tsv vs cells.sqlite, rows that differ | 0 | 0 | yes |", done.stdout)

    def test_a_table_that_differs_from_cells_sqlite_fails(self):
        db = sqlite3.connect(self.f.lge / "project.lungfish" / "Analyses" / "tenx-s.lungfishrnaseq" / "cells.sqlite")
        db.execute("UPDATE cells SET genes = genes + 1 WHERE cell = 2")
        db.commit()
        db.close()
        done = self.check()
        self.assertEqual(done.returncode, 1)
        self.assertIn("| s | tenx | scanpy-cells.tsv vs cells.sqlite, rows that differ | 0 | 1 | NO |", done.stdout)
        self.assertIn("| s | solo | scanpy-cells.tsv vs cells.sqlite, rows that differ | 0 | 0 | yes |", done.stdout)

    def test_a_not_host_count_that_genes_tsv_does_not_hold_fails(self):
        path = self.f.export("solo", "s") / "genes.tsv"
        path.write_text(path.read_text().replace("G3\tGene3\tfalse", "G3\tGene3\ttrue"))
        done = self.check()
        self.assertEqual(done.returncode, 1)
        self.assertIn("| s | solo | not-host features | 1 | 0 | NO |", done.stdout)
        self.assertIn("| s | tenx | not-host features | 0 | 0 | yes |", done.stdout)

    def test_an_exported_matrix_that_is_not_the_tools_file_fails(self):
        path = self.f.export("tenx", "s") / "s" / "matrix.mtx.gz"
        path.write_bytes(path.read_bytes() + b"x")
        done = self.check()
        self.assertEqual(done.returncode, 1)
        self.assertIn("| s | tenx | matrix files equal to the tool's own | 3 | 2 | NO |", done.stdout)

    def test_a_failed_scanpy_run_fails(self):
        write(self.f.log("solo", "s", "scanpy", "status"), "1\n")
        done = self.check()
        self.assertEqual(done.returncode, 1)
        self.assertIn("| s | solo | scanpy.py exit status | 0 | 1 | NO |", done.stdout)

    def test_seurat_without_seurat_may_stop_in_words_and_in_no_other_way(self):
        self.assertIn("| s | solo | seurat.R (env) exit status | 0, or 1 with the words | 1 with the words | yes |", self.check().stdout)
        write(self.f.log("solo", "s", "seurat-env", "err"), "Error: boom\n")
        done = self.check()
        self.assertEqual(done.returncode, 1)
        self.assertIn("| s | solo | seurat.R (env) exit status | 0, or 1 with the words | 1 without the words | NO |", done.stdout)

    def test_an_object_that_holds_other_cells_than_the_table_fails(self):
        write(self.f.log("solo", "s", "seurat", "out"), "cells s 3\ncells total 3\nnot-host features 0\nAn object of class Seurat \n4 features across 2 samples within 1 assay \n")
        done = self.check()
        self.assertEqual(done.returncode, 1)
        self.assertIn("| s | solo | Seurat object features and cells | 4 x 3 | 4 x 2 | NO |", done.stdout)
        self.assertIn("| s | solo | AnnData n_obs and n_vars | 3 x 4 | 3 x 4 | yes |", done.stdout)

    def test_a_missing_export_fails_in_words(self):
        shutil.rmtree(self.f.export("tenx", "s"))
        done = self.check()
        self.assertEqual(done.returncode, 1)
        self.assertIn("is missing, so the export of s is not checked", done.stderr)

    def test_the_run_folder_comes_from_LGE_RUN(self):
        self.assertEqual(self.check(run="OTHER").returncode, 1, "the run OTHER left no export")
        self.assertEqual(self.check(run="").returncode, 0, "an empty LGE_RUN reads as the default, as the shell does")

    def test_every_set_is_checked_and_one_wrong_set_fails_the_check(self):
        self.f.add("t", n=4)
        write(self.f.work / "solo" / "t" / "Solo.out" / "Gene" / "Summary.csv", "Estimated Number of Cells,5\n")
        done = self.check("s", "t")
        self.assertEqual(done.returncode, 1)
        self.assertIn("| s | solo | scanpy.py cells total | 3 | 3 | yes |", done.stdout)
        self.assertIn("| t | solo | scanpy.py cells total | 5 | 4 | NO |", done.stdout)


if __name__ == "__main__":
    unittest.main()
