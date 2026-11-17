"""Tests for the per-genome cell-call step of scripts/repro/rnaseq/tenx-controls/compare_gx.py (GX-PER-GENOME-CALL-STEP).

Run from the repository root:
    python3 -m unittest discover -s scripts/tests -p 'test_compare_gx.py' -v

For a two-prefix set (hgmm_1k_v3, hg19 and mm10) compare_gx.py makes the per-genome cell calls itself, as 5.0's
stage_pergenome does (tenx-controls/run.sh:204-212): compare.py split-genomes on the returned Gene/raw, then STAR
soloCellFiltering with EmptyDrops_CR on each half. Every test works in a temporary folder. A fake STAR (a shell script that
records its argument list and folder and writes barcodes.tsv into the output folder it is given) and a fake python (a shell
script that records the split-genomes argument list and makes the two raw folders) stand in for STAR 2.7.11b and compare.py,
so no STAR, no numpy and no 10x data are needed. The real split and the real STAR are proved on the saved GX H files, in the
report of lane FIX-GX-PERGENOME.
"""
import contextlib
import importlib.util
import io
import os
import re
import shutil
import tempfile
import unittest
from pathlib import Path

CONTROLS = Path(__file__).resolve().parents[1] / "repro" / "rnaseq" / "tenx-controls"
RUN_ARGS = ["1000", "0.99", "10", "45000", "90000", "500", "0.01", "20000", "0.01", "10000"]


def load(name):
    spec = importlib.util.spec_from_file_location(name, CONTROLS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


compare_gx = load("compare_gx")


class PergenomeCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="test_compare_gx_")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.log = self.tmp / "calls.log"
        self.work = self.tmp / "work"
        self.work.mkdir()
        self.solo_out = self.tmp / "returned" / "Solo.out"
        (self.solo_out / "Gene" / "raw").mkdir(parents=True)
        self.base = self.work / "solo" / "hgmm_1k_v3" / "pergenome"

    def fake_star(self, version="2.7.11b", exit_code=0, write_barcodes=True):
        path = self.tmp / "STAR"
        lines = ["#!/bin/sh",
                 'if [ "$1" = "--version" ]; then echo "%s"; exit 0; fi' % version,
                 'echo "cwd=$(pwd)" >> "%s"' % self.log,
                 'for a in "$@"; do echo "arg=$a" >> "%s"; done' % self.log]
        if write_barcodes:
            lines.append('printf "AAAC-1\\nAAAG-1\\n" > "${4}barcodes.tsv"')
        lines.append("exit %d" % exit_code)
        path.write_text("\n".join(lines) + "\n")
        path.chmod(0o755)
        return str(path)

    def fake_python(self, exit_code=0):
        path = self.tmp / "python"
        path.write_text("\n".join([
            "#!/bin/sh",
            'echo "python $*" >> "%s"' % self.log,
            'for p in "$6" "$7"; do mkdir -p "${5}_$p"; done',
            "exit %d" % exit_code]) + "\n")
        path.chmod(0o755)
        return str(path)

    def run_step(self, star=None, python=None):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            calls = compare_gx.pergenome_step(str(self.solo_out), str(self.work), "hgmm_1k_v3",
                                              star or self.fake_star(), python or self.fake_python())
        return calls, out.getvalue()

    def logged(self):
        return self.log.read_text().splitlines()


class PergenomeStepTests(PergenomeCase):
    def test_the_split_reads_the_returned_gene_raw(self):
        self.run_step()
        compare_py = str(CONTROLS / "compare.py")
        self.assertEqual(self.logged()[0], "python -I %s split-genomes %s %s hg19 mm10"
                         % (compare_py, self.solo_out / "Gene" / "raw", self.base / "raw"))

    def test_each_genome_is_called_with_the_arguments_of_run_sh(self):
        calls, _ = self.run_step()
        expected = []
        for genome in ("hg19", "mm10"):
            expected += ["cwd=%s" % (self.base / ("STARsolo_Gene_" + genome)),
                         "arg=--runMode", "arg=soloCellFiltering",
                         "arg=%s/" % (self.base / ("raw_" + genome)),
                         "arg=%s/" % (self.base / ("STARsolo_Gene_" + genome)),
                         "arg=--soloCellFilter", "arg=EmptyDrops_CR"] + ["arg=" + value for value in RUN_ARGS]
        self.assertEqual(self.logged()[1:], expected)
        self.assertEqual(calls, {genome: str(self.base / ("STARsolo_Gene_" + genome) / "barcodes.tsv")
                                 for genome in ("hg19", "mm10")})

    def test_the_numbers_equal_the_ones_run_sh_passes_to_star(self):
        text = (CONTROLS / "run.sh").read_text()
        block = re.search(r"^stage_pergenome\(\) \{\n(.*?)^\}", text, re.S | re.M).group(1)
        written = re.search(r"--soloCellFilter EmptyDrops_CR ([0-9. ]+)", block).group(1).split()
        self.assertEqual(written, RUN_ARGS)
        self.assertEqual(compare_gx.CELL_FILTER, ["--soloCellFilter", "EmptyDrops_CR"] + written)

    def test_only_the_two_prefix_set_gets_the_step(self):
        self.assertEqual(compare_gx.TWO_PREFIX_SETS, {"hgmm_1k_v3": ("hg19", "mm10")})

    def test_an_earlier_pergenome_folder_is_never_written_over(self):
        self.base.mkdir(parents=True)
        (self.base / "kept").write_text("earlier")
        with self.assertRaises(FileExistsError):
            self.run_step()
        self.assertEqual((self.base / "kept").read_text(), "earlier")
        self.assertFalse(self.log.exists())

    def test_a_star_that_fails_or_writes_no_barcodes_is_a_step_error(self):
        with self.assertRaises(compare_gx.StepError):
            self.run_step(star=self.fake_star(exit_code=1))
        shutil.rmtree(self.work / "solo")
        with self.assertRaises(compare_gx.StepError):
            self.run_step(star=self.fake_star(write_barcodes=False))

    def test_a_failed_split_stops_before_star_runs(self):
        with self.assertRaises(compare_gx.StepError):
            self.run_step(python=self.fake_python(exit_code=1))
        self.assertNotIn("cwd=", "\n".join(self.logged()))


class StarVersionTests(PergenomeCase):
    def test_the_5_0_environments_star_is_accepted(self):
        self.assertEqual(compare_gx.check_star(self.fake_star()), "2.7.11b")

    def test_another_star_or_a_missing_one_is_refused(self):
        with self.assertRaises(compare_gx.StepError):
            compare_gx.check_star(self.fake_star(version="2.7.3a"))
        with self.assertRaises(compare_gx.StepError):
            compare_gx.check_star(str(self.tmp / "no-such-STAR"))


class SpeciesBarTests(unittest.TestCase):
    LABEL = "STARsolo_Gene:pergenome"
    # GX H's figures (SCR/lanes/GX-H-P2.md:92-96): LGE, 10x
    ROWS = {LABEL: {"cr_umi_purity": ("0.99666", "0.99700", ""), "gem_class_agreement_shared": ("1.00000", "1.0", ""),
                    "hg19_cells": ("502", "504", ""), "mm10_cells": ("539", "543", ""),
                    "fraction_gems_gt1_cell": ("0.00192", "0.002", ""), "cells_union": ("1040", "1046", "")}}

    def table(self, rows):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            compare_gx.bars_table(self.LABEL, rows, compare_gx.SPECIES_BARS, compare_gx.SPECIES_ALSO)
        return out.getvalue()

    def test_the_four_species_bars_are_five_rows_and_all_meet_on_gx_h(self):
        self.assertEqual([bar[1] for bar in compare_gx.SPECIES_BARS],
                         ["cr_umi_purity", "gem_class_agreement_shared", "hg19_cells", "mm10_cells", "fraction_gems_gt1_cell"])
        text = self.table(self.ROWS)
        self.assertEqual(text.count("meets"), 5, text)
        self.assertNotIn("MISSES", text)
        self.assertIn("cells_union", text)

    def test_each_bar_misses_past_its_number(self):
        for measure, ours in (("cr_umi_purity", "0.99100"), ("gem_class_agreement_shared", "0.98900"), ("hg19_cells", "470"),
                              ("mm10_cells", "500"), ("fraction_gems_gt1_cell", "0.00610")):
            rows = {self.LABEL: dict(self.ROWS[self.LABEL])}
            rows[self.LABEL][measure] = (ours,) + self.ROWS[self.LABEL][measure][1:]
            text = self.table(rows)
            self.assertEqual(text.count("MISSES"), 1, (measure, text))
            self.assertEqual(text.count("meets"), 4, (measure, text))

    def test_a_row_the_comparer_did_not_write_prints_no_row(self):
        rows = {self.LABEL: {"hg19_cells": ("502", "504", "")}}
        self.assertEqual(self.table(rows).count("no row"), 4)


if __name__ == "__main__":
    unittest.main()
