"""Tests for scripts/checks/contract-size.py. Each test builds a throwaway tree in a temporary folder."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "checks" / "contract-size.py"
BASELINE = "scripts/checks/contract-size.baseline"
SCOPE = "docs/contracts/SCOPE-AND-DELIVERY.md"  # a cap of 10 KB, 10,240 bytes
LONG = "docs/contracts/ADDING-AN-OPERATION.md"  # the default contract cap of 20 KB, 20,480 bytes
MACHINES = "docs/contracts/MACHINES.md"  # a cap of 12 KB, 12,288 bytes
CAPS = (
    ("AGENTS.md", 6 * 1024),
    ("Sources/LungfishCore/AGENTS.md", 12 * 1024),
    (".claude/agents/lge-worker.md", 6 * 1024),
    ("docs/contracts/SCOPE-AND-DELIVERY.md", 10 * 1024),
    ("docs/contracts/OWNER-DIRECTIONS.md", 6 * 1024),
    ("docs/contracts/RUNNING-A-PHASE-SESSION.md", 12 * 1024),
    ("docs/contracts/VERIFICATION-ORDER.md", 12 * 1024),
    ("docs/contracts/EXPERT-PANEL.md", 10 * 1024),
    ("docs/contracts/MACHINES.md", 12 * 1024),
    ("docs/contracts/analysis-surface-checklist.md", 10 * 1024),
    ("docs/contracts/README.md", 6 * 1024),
    ("docs/contracts/RECORDING-PROVENANCE.md", 20 * 1024),
)


class ContractSizeTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def put(self, relative, size):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x" * size)
        return path

    def baseline(self, *lines):
        path = self.root / BASELINE
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(f"{line}\n" for line in lines))
        return path

    def baseline_text(self):
        return (self.root / BASELINE).read_text()

    def run_script(self, *arguments):
        command = [sys.executable, str(SCRIPT), "--root", str(self.root), *arguments]
        return subprocess.run(command, capture_output=True, text=True)

    def test_a_file_at_its_cap_passes_and_one_byte_over_fails(self):
        for relative, cap in CAPS:
            with self.subTest(relative):
                path = self.put(relative, cap)
                result = self.run_script()
                self.assertEqual((result.returncode, result.stderr), (0, ""))
                path.write_bytes(b"x" * (cap + 1))
                result = self.run_script()
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"{relative} is {cap + 1} bytes, over its cap of {cap}", result.stderr)
                path.unlink()

    def test_files_outside_the_covered_globs_are_ignored(self):
        for relative in ("docs/plans/big.md", "docs/contracts/notes/deep.md", "Sources/AGENTS.md", "README.md"):
            self.put(relative, 100 * 1024)
        result = self.run_script()
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        self.assertIn("ok (0 covered files", result.stdout)

    def test_a_file_over_its_cap_at_its_baseline_passes(self):
        self.put(SCOPE, 12000)
        self.baseline(f"{SCOPE} 10240 12000")
        result = self.run_script()
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        self.assertIn("ok (1 covered files, 1 over their caps at their baselines)", result.stdout)

    def test_a_file_grown_past_its_baseline_by_one_byte_fails(self):
        path = self.put(SCOPE, 12000)
        self.baseline(f"{SCOPE} 10240 12000")
        self.assertEqual(self.run_script().returncode, 0)
        with open(path, "ab") as handle:
            handle.write(b"x")
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.splitlines(), [
            f"contract-size: {SCOPE} is 12001 bytes, over its cap of 10240 and larger than its "
            "baseline of 12000 (a file over its cap may only shrink)"])

    def test_a_new_file_over_its_cap_fails(self):
        self.put(LONG, 20481)
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.splitlines(), [
            f"contract-size: {LONG} is 20481 bytes, over its cap of 20480, and has no line in {BASELINE}"])

    def test_a_line_for_a_gone_file_fails(self):
        self.baseline(f"{LONG} 20480 30000")
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.splitlines(), [
            f"contract-size: {BASELINE} names {LONG}, which is gone or not a covered file (run --update)"])

    def test_a_line_for_a_file_now_at_its_cap_fails(self):
        self.put(LONG, 20480)
        self.baseline(f"{LONG} 20480 30000")
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.splitlines(), [
            f"contract-size: {LONG} is 20480 bytes, at or under its cap of 20480, "
            f"so its line in {BASELINE} must go (run --update)"])

    def test_a_line_that_holds_another_cap_than_the_script_fails(self):
        self.put(SCOPE, 12000)
        self.baseline(f"{SCOPE} 20480 12000")
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.splitlines(), [
            f"contract-size: {SCOPE} has the cap 20480 in {BASELINE} but 10240 in this script (run --update)"])

    def test_a_malformed_or_repeated_line_fails(self):
        self.put(SCOPE, 12000)
        self.baseline(f"{SCOPE} 10240 12000", f"{SCOPE} 10240 11000", "not a line")
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        faults = result.stderr.splitlines()
        self.assertEqual(len(faults), 2, faults)
        self.assertIn(f"{BASELINE}:2: {SCOPE} has a second line", faults[0])
        self.assertIn(f"{BASELINE}:3: expected `<path> <cap bytes> <baseline bytes>`", faults[1])

    def test_an_unreadable_baseline_exits_2(self):
        self.baseline("x")
        (self.root / BASELINE).write_bytes(b"\xff\xfe\n")
        self.assertEqual(self.run_script().returncode, 2)

    def test_update_lowers_a_line_and_removes_the_stale_lines_in_path_order(self):
        self.put("AGENTS.md", 7000)  # shrank from 8000
        self.put(SCOPE, 12000)  # still at its baseline
        self.put(LONG, 20000)  # now under its cap
        self.baseline(f"{SCOPE} 10240 12000", f"{LONG} 20480 30000", "AGENTS.md 6144 8000",
                      "docs/contracts/GONE.md 20480 25000")
        result = self.run_script("--update")
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        self.assertIn("lowered AGENTS.md from 8000 to 7000", result.stdout)
        self.assertEqual(self.baseline_text(), f"AGENTS.md 6144 7000\n{SCOPE} 10240 12000\n")
        self.assertEqual(self.run_script().returncode, 0)

    def test_update_refuses_to_raise_a_line(self):
        path = self.put(SCOPE, 12000)
        self.baseline(f"{SCOPE} 10240 12000")
        path.write_bytes(b"x" * 12001)
        result = self.run_script("--update")
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"refused to raise the baseline: {SCOPE} is 12001 bytes", result.stderr)
        self.assertEqual(self.baseline_text(), f"{SCOPE} 10240 12000\n")

    def test_update_refuses_to_add_a_line_for_a_new_file(self):
        self.put(SCOPE, 12000)
        self.put(LONG, 25000)
        self.baseline(f"{SCOPE} 10240 12000")
        result = self.run_script("--update")
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"refused to raise the baseline: {LONG} is 25000 bytes", result.stderr)
        self.assertEqual(self.baseline_text(), f"{SCOPE} 10240 12000\n")

    def test_update_lowers_one_line_and_still_refuses_the_growth_of_another(self):
        self.put(MACHINES, 13000)  # shrank from 14000
        self.put(SCOPE, 12001)  # grew from 12000
        self.baseline(f"{MACHINES} 12288 14000", f"{SCOPE} 10240 12000")
        result = self.run_script("--update")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.baseline_text(), f"{MACHINES} 12288 13000\n{SCOPE} 10240 12000\n")

    def test_update_writes_a_first_baseline_when_there_is_none(self):
        self.put(SCOPE, 12000)
        self.put(LONG, 20480)
        self.put("AGENTS.md", 7000)
        result = self.run_script("--update")
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        self.assertEqual(self.baseline_text(), f"AGENTS.md 6144 7000\n{SCOPE} 10240 12000\n")
        self.assertEqual(self.run_script().returncode, 0)

    def test_print_lists_every_covered_file_with_its_size_cap_and_state(self):
        self.put("AGENTS.md", 7000)
        self.put(SCOPE, 9000)
        self.put(LONG, 25000)
        self.put(MACHINES, 13000)
        self.baseline("AGENTS.md 6144 7000", f"{MACHINES} 12288 14000", "docs/contracts/GONE.md 20480 22000")
        result = self.run_script("--print")
        self.assertEqual(result.returncode, 0)
        lines = [line.split() for line in result.stdout.splitlines()]
        self.assertEqual(lines, [
            ["state", "bytes", "cap", "baseline", "path"],
            ["held", "7000", "6144", "7000", "AGENTS.md"],
            ["NEW", "25000", "20480", "-", LONG],
            ["GONE", "-", "20480", "22000", "docs/contracts/GONE.md"],
            ["shrunk", "13000", "12288", "14000", MACHINES],
            ["under", "9000", "10240", "-", SCOPE]])


if __name__ == "__main__":
    unittest.main()
