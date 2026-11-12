"""Tests for scripts/checks/backlog.py.

Each test builds a tiny pair of backlog files in a temporary folder and runs the script
against it with --root. The real files are never read or changed.
"""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "checks" / "backlog.py"
TABLE = "| Id | Effect on results or users | Severity | Field | Source |\n|---|---|---|---|---|\n"
COLUMNS = "id\tseverity\tfield\teffect\tsource\tphase_filed\tkeep\n"


def md(row_id, severity="S1", effect="A wrong number.", field="BIO", source="src"):
    return f"| {row_id} | {effect} | {severity} | {field} | {source} |\n"


def tsv(row_id, severity="S3", effect="A cosmetic flaw.", field="UX", source="src", filed="4", keep=""):
    return "\t".join([row_id, severity, field, effect, source, filed, keep]) + "\n"


def backlog_text(results="", phase5="", phase6="", now="5"):
    def section(rows):
        return TABLE + rows if rows else "No open row has this phase as its target.\n"

    return (
        "# Backlog\n\n" + (f"Phase now: {now}\n\n" if now else "") + "Header words.\n\n"
        "## Results and data\n\n" + section(results) + "\n"
        "## Phase 5\n\n" + section(phase5) + "\n"
        "## Phase 6\n\n" + section(phase6)
    )


class BacklogCase(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.plans = self.root / "docs" / "plans"
        self.plans.mkdir(parents=True)

    def write(self, backlog=None, later=None):
        (self.plans / "BACKLOG.md").write_text(backlog if backlog is not None else backlog_text(), encoding="utf-8")
        (self.plans / "backlog-later.tsv").write_text(later if later is not None else COLUMNS, encoding="utf-8")

    def run_script(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root), *args],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def faults(self, backlog=None, later=None):
        self.write(backlog, later)
        result = self.run_script()
        return result.returncode, result.stderr.strip().splitlines()

    def assertFault(self, lines, *words):
        self.assertTrue(any(all(word in line for word in words) for line in lines), lines)


class CapAndCleanTests(BacklogCase):
    def test_clean_files_pass(self):
        results = (md("ROW-A") + md("ROW-B", "S2") + md("ROW-C", "S3 until measured")
                   + md("ROW-D", "S? probe") + md("ROW-E", "S3 (unknown)"))
        later = COLUMNS + tsv("ROW-L") + tsv("ROW-M", "S4", filed="3", keep="results")
        self.write(backlog_text(results=results, phase5=md("ROW-P", "S3")), later)
        result = self.run_script()
        self.assertEqual((result.returncode, result.stderr), (0, ""), result.stdout)
        self.assertIn("backlog: ok (6 rows in BACKLOG.md, 2 in backlog-later.tsv)", result.stdout)

    def test_backlog_cap_is_81920_bytes(self):
        pad = 81920 - len(backlog_text(results=md("ROW-A", effect="E")).encode())
        at_cap = backlog_text(results=md("ROW-A", effect="E" + "x" * pad))
        self.assertEqual(len(at_cap.encode()), 81920)
        self.assertEqual(self.faults(at_cap)[0], 0)
        code, lines = self.faults(at_cap.replace("E" + "x" * pad, "E" + "x" * (pad + 1)))
        self.assertEqual(code, 1)
        self.assertFault(lines, "docs/plans/BACKLOG.md", "81921 bytes", "81920-byte cap")

    def test_later_cap_is_460800_bytes(self):
        pad = 460800 - len((COLUMNS + tsv("ROW-L", effect="E")).encode())
        at_cap = COLUMNS + tsv("ROW-L", effect="E" + "x" * pad)
        self.assertEqual(len(at_cap.encode()), 460800)
        self.assertEqual(self.faults(later=at_cap)[0], 0)
        code, lines = self.faults(later=at_cap.replace("E" + "x" * pad, "E" + "x" * (pad + 1)))
        self.assertEqual(code, 1)
        self.assertFault(lines, "docs/plans/backlog-later.tsv", "460801 bytes", "460800-byte cap")

    def test_missing_files_are_faults(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.count("file not found"), 2)


class RowFaultTests(BacklogCase):
    def test_done_rows_fault_in_both_files(self):
        for effect in ("Done in 3.2 (abc1234).", "fixed in the viewer.", "CLOSED by hand.", "Landed in 3.3."):
            code, lines = self.faults(backlog_text(results=md("ROW-A", effect=effect)))
            self.assertEqual(code, 1, effect)
            self.assertFault(lines, "BACKLOG.md:", "ROW-A", "begins with a done word")
            code, lines = self.faults(later=COLUMNS + tsv("ROW-L", effect=effect))
            self.assertEqual(code, 1, effect)
            self.assertFault(lines, "backlog-later.tsv:2", "ROW-L", "begins with a done word")

    def test_narrowed_and_look_alike_rows_pass(self):
        for effect in ("Narrowed in 3.2 (abc1234). Done in the viewer only.", "Doneness is not a start.", "Not done."):
            self.assertEqual(self.faults(backlog_text(results=md("ROW-A", effect=effect)))[0], 0, effect)
            self.assertEqual(self.faults(later=COLUMNS + tsv("ROW-L", effect=effect))[0], 0, effect)

    def test_malformed_backlog_rows(self):
        for row in ("| ROW-A | text | S1 | BIO |\n", md(""), "| ROW-A | a | b | S1 | BIO | src |\n"):
            code, lines = self.faults(backlog_text(results=row))
            self.assertEqual(code, 1, row)
            self.assertFault(lines, "BACKLOG.md:", "malformed row")

    def test_a_pipe_inside_a_cell_must_be_escaped(self):
        escaped = md("ROW-A", effect="Use a\\|b here.")
        self.assertEqual(self.faults(backlog_text(results=escaped))[0], 0)
        code, lines = self.faults(backlog_text(results=md("ROW-A", effect="Use a|b here.")))
        self.assertEqual(code, 1)
        self.assertFault(lines, "malformed row", "6 cells")

    def test_malformed_later_rows(self):
        rows = ("ROW-L\tS3\tUX\ttext\tsrc\t4\n", tsv(""), tsv("ROW-L", filed="four"), tsv("ROW-L", keep="maybe"), "\n")
        for row in rows:
            code, lines = self.faults(later=COLUMNS + row)
            self.assertEqual(code, 1, repr(row))
            self.assertFault(lines, "backlog-later.tsv:2")
        for keep in ("results", "data", "crash", "hang"):
            self.assertEqual(self.faults(later=COLUMNS + tsv("ROW-L", keep=keep))[0], 0, keep)

    def test_later_header_must_be_exact(self):
        code, lines = self.faults(later="id\tseverity\n" + tsv("ROW-L"))
        self.assertEqual(code, 1)
        self.assertFault(lines, "backlog-later.tsv:1", "header")

    def test_duplicate_ids_across_and_inside_files(self):
        code, lines = self.faults(backlog_text(results=md("ROW-A")), COLUMNS + tsv("ROW-A"))
        self.assertEqual(code, 1)
        self.assertFault(lines, "backlog-later.tsv:2", "ROW-A", "appears twice", "BACKLOG.md:")
        code, lines = self.faults(later=COLUMNS + tsv("ROW-L") + tsv("ROW-L"))
        self.assertEqual(code, 1)
        self.assertFault(lines, "backlog-later.tsv:3", "ROW-L", "appears twice")


class PlacementTests(BacklogCase):
    def test_results_section_holds_only_s1_s2_and_probe_rows(self):
        for severity in ("S3", "S4", "S3 (proposed)", "not rated"):
            code, lines = self.faults(backlog_text(results=md("ROW-A", severity)))
            self.assertEqual(code, 1, severity)
            self.assertFault(lines, "BACKLOG.md:", "ROW-A", "holds only S1, S2 and probe rows")

    def test_s1_s2_and_probe_rows_do_not_sit_in_a_phase_section(self):
        for severity in ("S1", "S2", "S3 until measured"):
            code, lines = self.faults(backlog_text(phase5=md("ROW-P", severity)))
            self.assertEqual(code, 1, severity)
            self.assertFault(lines, "ROW-P", "belong in Results and data")

    def test_later_file_rejects_s1_s2_and_probe_rows(self):
        for severity in ("S1", "S2 by effect", "S3 until measured", "S3 if seen", "S? probe",
                         "unrated (BIO rates it once the reach is read)"):
            code, lines = self.faults(later=COLUMNS + tsv("ROW-L", severity))
            self.assertEqual(code, 1, severity)
            self.assertFault(lines, "backlog-later.tsv:2", "ROW-L", "belong in BACKLOG.md under Results and data")

    def test_two_phase_rule_uses_phase_now_and_keep(self):
        now5, now6 = backlog_text(now="5"), backlog_text(now="6")
        self.assertEqual(self.faults(now5, COLUMNS + tsv("ROW-L", filed="4"))[0], 0)
        code, lines = self.faults(now5, COLUMNS + tsv("ROW-L", filed="3"))
        self.assertEqual(code, 1)
        self.assertFault(lines, "backlog-later.tsv:2", "ROW-L", "filed in phase 3", "phase 5", "keep empty")
        self.assertEqual(self.faults(now5, COLUMNS + tsv("ROW-L", filed="3", keep="hang"))[0], 0)
        self.assertEqual(self.faults(now6, COLUMNS + tsv("ROW-L", filed="4", keep="data"))[0], 0)
        code, lines = self.faults(now6, COLUMNS + tsv("ROW-L", filed="4"))
        self.assertEqual(code, 1)
        self.assertFault(lines, "ROW-L", "filed in phase 4", "phase 6")

    def test_header_needs_phase_now_and_the_first_section(self):
        code, lines = self.faults(backlog_text(now=None))
        self.assertEqual(code, 1)
        self.assertFault(lines, "Phase now: N")
        wrong = backlog_text().replace("## Results and data", "## Phase 4", 1)
        code, lines = self.faults(wrong)
        self.assertEqual(code, 1)
        self.assertFault(lines, "first section", "Results and data")


class ListTests(BacklogCase):
    def test_list_prints_one_phase_and_the_later_rows_filed_in_it(self):
        phase5 = md("ROW-P", "S3", field="UX") + md("ROW-Q", "S4", field="BIO, UX")
        self.write(backlog_text(results=md("ROW-A"), phase5=phase5, phase6=md("ROW-R", "S3")),
                   COLUMNS + tsv("ROW-L", filed="5") + tsv("ROW-M", filed="4"))
        listed = lambda *args: self.run_script("list", *args).stdout.splitlines()
        self.assertEqual(listed("--phase", "5"), ["ROW-P  S3  UX", "ROW-Q  S4  BIO, UX"])
        self.assertEqual(listed("--phase", "5", "--later"), ["ROW-P  S3  UX", "ROW-Q  S4  BIO, UX", "ROW-L  S3  UX"])
        self.assertEqual(listed("--phase", "6"), ["ROW-R  S3  BIO"])
        self.assertEqual(listed("--phase", "4", "--later"), ["ROW-M  S3  UX"])
        self.assertEqual(listed("--phase", "9"), [])


class CloseTests(BacklogCase):
    def test_close_removes_the_row_from_whichever_file_holds_it(self):
        backlog = backlog_text(results=md("ROW-A") + md("ROW-B"), phase5=md("ROW-P", "S3"))
        later = COLUMNS + tsv("ROW-L") + tsv("ROW-M")
        self.write(backlog, later)
        result = self.run_script("close", "ROW-B", "abc1234")
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "Backlog: ROW-B closed by abc1234"))
        self.assertEqual((self.plans / "BACKLOG.md").read_text(), backlog.replace(md("ROW-B"), ""))
        self.assertEqual((self.plans / "backlog-later.tsv").read_text(), later)
        result = self.run_script("close", "ROW-L", "def5678")
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "Backlog: ROW-L closed by def5678"))
        self.assertEqual((self.plans / "backlog-later.tsv").read_text(), COLUMNS + tsv("ROW-M"))

    def test_close_refuses_an_unknown_id_a_repeated_id_and_a_bad_commit(self):
        backlog, later = backlog_text(results=md("ROW-A")), COLUMNS + tsv("ROW-A")
        self.write(backlog, later)
        self.assertEqual(self.run_script("close", "NOPE", "abc1234").returncode, 1)
        self.assertEqual(self.run_script("close", "ROW-A", "abc1234").returncode, 1)
        self.assertEqual(self.run_script("close", "ROW-A", "two words").returncode, 2)
        self.assertEqual((self.plans / "BACKLOG.md").read_text(), backlog)
        self.assertEqual((self.plans / "backlog-later.tsv").read_text(), later)


class ClassifierTests(unittest.TestCase):
    def test_kind_and_is_done(self):
        spec = importlib.util.spec_from_file_location("backlog_under_test", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        cases = {
            "S1": "S1", "S1 by effect, rare reach": "S1", "S2": "S2", "S3": "other", "S4 (docs)": "other",
            "not rated": "other", "Not rated": "other", "S3 (proposed)": "other",
            "S3 until measured": "probe", "S3 (unknown)": "probe", "S? probe": "probe",
            "S3 (S1 if it happened)": "probe", "S3 now, S1 the day a caller passes rows": "probe",
            'S3 (re-rated by BIO from "S2 once the split lands")': "other",
            "unrated (BIO rates it once the reach is read)": "probe",
            "S3 leftover (the S2 is closed by a landing), a Known limit": "other",
        }
        for severity, expected in cases.items():
            self.assertEqual(module.kind(severity), expected, severity)
        self.assertTrue(module.is_done("  done in 3.2"))
        self.assertFalse(module.is_done("Narrowed in 3.2"))


if __name__ == "__main__":
    unittest.main()
