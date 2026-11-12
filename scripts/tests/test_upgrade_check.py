"""Tests for scripts/golden/upgrade_check.py with a stand-in lungfish-cli and a made two-result corpus.

    python3 -m unittest scripts.tests.test_upgrade_check

The stand-in answers only the calls the check makes. The real CLI is the job of
`upgrade_check.py` on the corpus in the golden cache.
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import stat
import sys
import tempfile
import unittest
from pathlib import Path

GOLDEN = Path(__file__).resolve().parents[1] / "golden"
sys.path.insert(0, str(GOLDEN))
sys.dont_write_bytecode = True

import upgrade_check  # noqa: E402

STAND_IN = '''#!PYTHON
import sys
from pathlib import Path
CHANGE = CHANGE_FLAG
args = sys.argv[1:]
if args == ["--version"]:
    print("2026.1.1")
elif args[:2] == ["bundle", "list"]:
    table = (Path(args[2]) / "table.tsv").read_text()
    print(table.replace("12", "13") if CHANGE else table, end="")
elif args[:2] == ["bundle", "info"]:
    print((Path(args[2]) / "info.json").read_text(), end="")
elif args[:2] == ["provenance", "verify"]:
    print("Signature valid")
    print("Signature:", args[2] + "/.lungfish-provenance.json.signature.json")
elif args[:2] == ["provenance", "export"]:
    out = Path(args[args.index("--output") + 1])
    out.mkdir()
    (out / "record.json").write_text((Path(args[2]) / ".lungfish-provenance.json").read_text())
elif args[0] == "universal-search":
    print("\\n".join(sorted(p.name for p in Path(args[1]).rglob("*") if p.is_dir())))
elif args[:2] == ["ops", "stats"]:
    print("0 operations")
else:
    print("unknown", args, file=sys.stderr)
    sys.exit(2)
'''


def make_cli(folder: Path, change_cell: bool) -> Path:
    folder.mkdir(parents=True)
    cli = folder / "lungfish-cli"
    cli.write_text(STAND_IN.replace("PYTHON", sys.executable).replace("CHANGE_FLAG", str(change_cell)))
    cli.chmod(cli.stat().st_mode | stat.S_IXUSR)
    return cli


def make_corpus(root: Path) -> Path:
    """One release with one project that holds two results, a reference bundle and an analysis."""
    project = root / "v1.0.0" / "demo" / "Demo.lungfish"
    for result in (project / "Reference Sequences" / "A.lungfishref", project / "Analyses" / "run-1"):
        result.mkdir(parents=True)
        (result / "table.tsv").write_text("gene\tcount\nalpha\t12\nbeta\t20\n")
        (result / "info.json").write_text('{"name": "' + result.name + '", "createdAt": "2026-11-01T10:00:00Z"}\n')
        (result / ".lungfish-provenance.json").write_text('{"step": "made", "createdAt": "2026-11-01T10:00:00Z"}\n')
    return project


def write_sums(root: Path) -> None:
    files = sorted(p for p in root.rglob("*") if p.is_file() and p.name != "SHA256SUMS")
    (root / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(root).as_posix()}\n" for p in files))


def run_main(*args: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = upgrade_check.main(list(args))
    return code, out.getvalue(), err.getvalue()


class UpgradeCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.corpus = self.root / "corpus"
        self.project = make_corpus(self.corpus)
        self.good = make_cli(self.root / "good", change_cell=False)
        self.bad = make_cli(self.root / "bad", change_cell=True)
        code, out, err = run_main("--capture", "--cli", str(self.good), "--corpus", str(self.corpus), "--only", "v1.0.0")
        self.assertEqual(code, 0, out + err)
        write_sums(self.corpus)

    def test_plan_has_verify_and_export_for_both_results(self) -> None:
        names = [name for name, _ in upgrade_check.plan(self.project)]
        self.assertEqual([n for n in names if n.startswith("verify ")],
                         ["verify Analyses/run-1", "verify Reference Sequences/A.lungfishref"])
        self.assertIn("export Reference Sequences/A.lungfishref", names)
        self.assertIn("tracks Reference Sequences/A.lungfishref", names)

    def test_same_outputs_pass_although_the_scratch_folder_differs(self) -> None:
        code, out, err = run_main("--cli", str(self.good), "--corpus", str(self.corpus))
        self.assertEqual(code, 0, out + err)
        self.assertIn("upgrade-check: passed, 1 projects", out)
        self.assertIn("0 differences", out)

    def test_a_changed_cell_exits_one_with_one_line(self) -> None:
        code, out, _ = run_main("--cli", str(self.bad), "--corpus", str(self.corpus))
        self.assertEqual(code, 1, out)
        lines = [line for line in out.splitlines() if "tracks_Reference_Sequences_A.lungfishref" in line]
        self.assertEqual(len(lines), 1, out)
        self.assertIn("alpha\\t12", lines[0])
        self.assertIn("alpha\\t13", lines[0])
        self.assertIn("upgrade-check: FAILED", out)

    def test_a_step_missing_from_expected_is_a_difference(self) -> None:
        expected = self.project.parent / "expected"
        next(expected.glob("001-ops-stats.txt")).unlink()
        write_sums(self.corpus)
        code, out, _ = run_main("--cli", str(self.good), "--corpus", str(self.corpus))
        self.assertEqual(code, 1)
        self.assertIn("001-ops-stats.txt: step is not in expected/", out)

    def test_a_missing_corpus_names_the_build_command(self) -> None:
        code, _, err = run_main("--cli", str(self.good), "--corpus", str(self.root / "nowhere"))
        self.assertEqual(code, 2)
        self.assertIn("build_upgrade_corpus.sh", err)

    def test_a_damaged_corpus_exits_two(self) -> None:
        (self.project / "Analyses" / "run-1" / "table.tsv").write_text("gene\tcount\nalpha\t99\n")
        code, _, err = run_main("--cli", str(self.good), "--corpus", str(self.corpus))
        self.assertEqual(code, 2)
        self.assertIn("Analyses/run-1/table.tsv: SHA-256 differs", err)


if __name__ == "__main__":
    unittest.main()
