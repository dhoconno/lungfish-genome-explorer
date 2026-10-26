"""A ratchet whose count falls writes its own lower baseline when it runs directly (scripts/ratchets/ratchet_baseline.py).

docs/contracts/SCOPE-AND-DELIVERY.md (Generated files) says so. A gate and the pre-push hook must never get that
write, because a changed source file ends a gate with "source changed during gate", and a baseline is never raised.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/ratchets/ratchet_baseline.py"
SPEC = importlib.util.spec_from_file_location("ratchet_baseline_under_test", HELPER)
HELPER_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER_MODULE)
READ_ONLY = HELPER_MODULE.READ_ONLY_VARIABLE
RATCHETS = ["concurrency-hatches", "durable-writes", "volume-portability", "path-helpers", "native-tool-runner-in-app",
            "unchecked-operation-start", "source-text-assertions", "process-spawn", "file-size", "tool-identity",
            "provenance-writers", "portable-imports"]

# A ratchet in the shape of the real ones. COUNT_FILE holds the current count. FAKE_RAISES makes --update write a
# number above the count, as a faulty ratchet would. FORMAT is "names" (name and count lines) or "single" (a number).
FAKE_RATCHET = textwrap.dedent('''\
    import os, sys
    from pathlib import Path
    BASELINE_FILE = Path(__file__).resolve().with_suffix(".baseline")
    COUNT = int(Path(__file__).with_name("count.txt").read_text())
    SINGLE = os.environ.get("FORMAT") == "single"

    def read_baseline():
        text = BASELINE_FILE.read_text().strip().splitlines()
        return int(text[0]) if SINGLE else int(text[-1].rpartition(" ")[2])

    def main(argv):
        if "--update" in argv:
            number = COUNT + (10 if os.environ.get("FAKE_RAISES") else 0)
            BASELINE_FILE.write_text(f"{number}\\n" if SINGLE else f"# fake baseline\\nthings {number}\\n")
            print("Updated baseline")
            return 0
        if not BASELINE_FILE.exists():
            return 1
        if COUNT > read_baseline():
            print("fake: the count rose", file=sys.stderr)
            return 1
        print("fake: ok")
        return 0

    if __name__ == "__main__":
        import ratchet_baseline
        sys.exit(ratchet_baseline.run(main, sys.argv[1:], BASELINE_FILE))
''')


def clean_env(**extra):
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", READ_ONLY)}
    env.update(extra)
    return env


def run_fake(baseline, count, *, single=False, env=None, argv=()):
    """Run the fake ratchet with a baseline text and a count. Returns the process and the baseline text after."""
    with tempfile.TemporaryDirectory(prefix="lungfish-ratchet-test-") as temp:
        folder = Path(temp)
        (folder / "ratchet_baseline.py").write_text(HELPER.read_text(encoding="utf-8"), encoding="utf-8")
        (folder / "fake.sh").write_text(FAKE_RATCHET, encoding="utf-8")
        (folder / "count.txt").write_text(str(count))
        if baseline is not None:
            (folder / "fake.baseline").write_text(baseline, encoding="utf-8")
        environment = clean_env(**({"FORMAT": "single"} if single else {}))
        environment.update(env or {})
        process = subprocess.run([sys.executable, str(folder / "fake.sh"), *argv], capture_output=True, text=True,
                                 env=environment, cwd=folder)
        path = folder / "fake.baseline"
        return process, path.read_text(encoding="utf-8") if path.exists() else None


HAND_WRITTEN = "# written by hand, with a comment that --update would not write\nthings 5\n"


class LoweringTests(unittest.TestCase):
    def test_a_count_that_fell_lowers_the_baseline_and_says_so(self):
        process, after = run_fake(HAND_WRITTEN, 3)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(after, "# fake baseline\nthings 3\n")
        self.assertIn("things fell from 5 to 3, so the baseline is lowered", process.stdout)

    def test_a_single_number_baseline_lowers_the_same_way(self):
        process, after = run_fake("5\n", 3, single=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(after, "3\n")
        self.assertIn("the count fell from 5 to 3", process.stdout)

    def test_a_run_that_finds_nothing_lower_changes_no_byte(self):
        process, after = run_fake(HAND_WRITTEN, 5)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(after, HAND_WRITTEN)
        self.assertNotIn("lowered", process.stdout)

    def test_a_count_that_rose_fails_and_never_raises_the_baseline(self):
        process, after = run_fake(HAND_WRITTEN, 7)
        self.assertEqual(process.returncode, 1)
        self.assertEqual(after, HAND_WRITTEN)

    def test_a_ratchet_whose_update_would_raise_a_number_leaves_the_baseline_alone(self):
        process, after = run_fake(HAND_WRITTEN, 3, env={"FAKE_RAISES": "1"})
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(after, HAND_WRITTEN)

    def test_a_gate_and_a_hook_run_read_only(self):
        for label, env in (("the gate", {READ_ONLY: "1"}), ("a git hook", {"GIT_DIR": ".git"})):
            with self.subTest(label):
                process, after = run_fake(HAND_WRITTEN, 3, env=env)
                self.assertEqual(process.returncode, 0, process.stderr)
                self.assertEqual(after, HAND_WRITTEN)
        process, after = run_fake(HAND_WRITTEN, 3, env={READ_ONLY: "0"})
        self.assertNotEqual(after, HAND_WRITTEN)

    def test_the_flags_and_a_missing_baseline_are_left_to_the_ratchet(self):
        process, after = run_fake(None, 3)
        self.assertEqual((process.returncode, after), (1, None))
        process, after = run_fake(HAND_WRITTEN, 3, argv=["--update"])
        self.assertEqual(after, "# fake baseline\nthings 3\n")
        self.assertNotIn("lowered", process.stdout)

    def test_the_helper_reads_names_and_never_accepts_a_raise(self):
        helper = HELPER_MODULE
        self.assertEqual(helper.numbers("# c\n7\n"), {"": 7})
        self.assertEqual(helper.numbers("# c\nSources/A B.swift 801\nb 2\nbad x\n"), {"Sources/A B.swift": 801, "b": 2})
        self.assertEqual(helper.lowered("a 4\nb 2\n", "a 4\nb 1\n"), {"b": (2, 1)})
        self.assertEqual(helper.lowered("a 4\nb 2\n", "a 4\n"), {"b": (2, 0)})
        self.assertEqual(helper.lowered("a 4\n", "a 4\n"), {})
        self.assertIsNone(helper.lowered("a 4\n", "a 5\n"))
        self.assertIsNone(helper.lowered("a 4\n", "a 4\nb 1\n"))
        self.assertTrue(helper.read_only({"GIT_DIR": ".git"}))
        self.assertTrue(helper.read_only({READ_ONLY: "1"}))
        self.assertFalse(helper.read_only({}))
        self.assertFalse(helper.read_only({READ_ONLY: "0"}))


class RatchetWiringTests(unittest.TestCase):
    def test_every_ratchet_with_a_baseline_file_calls_the_one_helper(self):
        for name in RATCHETS:
            with self.subTest(name):
                text = (ROOT / "scripts/ratchets" / (name + ".sh")).read_text(encoding="utf-8")
                self.assertIn("    sys.exit(ratchet_baseline.run(main, sys.argv[1:], BASELINE_FILE))\n", text)
                self.assertNotIn("def lower", text)
                self.assertTrue((ROOT / "scripts/ratchets" / (name + ".baseline")).is_file())

    def test_the_gate_exports_the_read_only_variable_before_it_runs_anything(self):
        gate = (ROOT / "scripts/full-suite-gate.sh").read_text(encoding="utf-8")
        self.assertIn("export LUNGFISH_RATCHET_READ_ONLY=1\n", gate)
        self.assertLess(gate.index("export LUNGFISH_RATCHET_READ_ONLY=1"), gate.index("run_gate() {"))

    def test_a_read_only_run_of_each_real_ratchet_passes_and_writes_nothing(self):
        for name in RATCHETS:
            with self.subTest(name):
                path = ROOT / "scripts/ratchets" / (name + ".baseline")
                before = path.read_bytes()
                process = subprocess.run([sys.executable, str(ROOT / "scripts/ratchets" / (name + ".sh"))], cwd=ROOT,
                                         capture_output=True, text=True, env=clean_env(**{READ_ONLY: "1"}))
                self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
                self.assertEqual(path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
