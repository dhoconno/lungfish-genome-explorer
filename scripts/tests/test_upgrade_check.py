"""Tests for scripts/golden/upgrade_check.py with a stand-in lungfish-cli and a made two-result corpus.

    python3 -m unittest scripts.tests.test_upgrade_check

The stand-in answers only the calls the check makes. The real CLI is the job of
`upgrade_check.py` on the corpus in the golden cache.
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

GOLDEN = Path(__file__).resolve().parents[1] / "golden"
sys.path.insert(0, str(GOLDEN))
sys.dont_write_bytecode = True

import upgrade_check  # noqa: E402

STAND_IN = '''#!PYTHON
import hashlib, json, os, sys, time, uuid
from pathlib import Path
CHANGE = CHANGE_FLAG
REWRITE_INPUT = REWRITE_FLAG
EDIT_EXPORT = EDIT_FLAG
TOOL_DIR = TOOLDIR_TEXT
TOOL_ROOT = TOOLROOT_TEXT
TOOL_ENV = TOOLENV_TEXT
VERSION = "VERSION_TEXT"
BUILD = "BUILD_TEXT"
args = sys.argv[1:]


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


if args == ["--version"]:
    print(VERSION)
elif args[:2] == ["bundle", "list"]:
    table = (Path(args[2]) / "table.tsv").read_text()
    print(table.replace("12", "13") if CHANGE else table, end="")
elif args[:2] == ["bundle", "info"]:
    print((Path(args[2]) / "info.json").read_text(), end="")
elif args[:2] == ["provenance", "verify"]:
    print("Signature valid")
    print("Signature:", args[2] + "/.lungfish-provenance.json.signature.json")
elif args[:2] == ["provenance", "export"]:
    # Like the real exporter, this writes a file that holds a random ID, the time, its own folder
    # and the build that exports, and a record that lists the checksum and size of that file.
    # It also expands the stored <tool-root> to the managed tool root of the build that exports,
    # which sits under the home folder of the account that runs it (~/.lungfish for a Preview,
    # ~/.lungfish-stable for a Stable, ~/.lungfish-debug for a Debug build).
    out = Path(args[args.index("--output") + 1])
    out.mkdir()
    source = Path(args[2]) / ".lungfish-provenance.json"
    if REWRITE_INPUT:
        source.write_text(source.read_text() + "\\n")
    home = os.environ["HOME"]
    root = TOOL_ROOT or home + "/" + TOOL_DIR + "/conda"
    stored = source.read_text().replace("<tool-root>", root).replace("/envs/samtools/", "/envs/" + TOOL_ENV + "/")
    record = json.loads(stored)
    record["cacheDir"] = home + "/Library/Caches/lungfish"
    if EDIT_EXPORT:
        record["step"] = "edited"
    body = out / "provenance.json"
    body.write_text(json.dumps({"id": str(uuid.uuid4()), "exportedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
                                "folder": str(out), "appVersion": f"Lungfish {VERSION} ({BUILD})",
                                "source": record}, indent=2) + "\\n")
    # The real exporter also copies the source records to a name under external/ that holds their full path.
    copy = out / "external" / str(source.parent).removeprefix("/private").lstrip("/")
    copy.mkdir(parents=True)
    (copy / "note.txt").write_text("copied\\n")
    files = [{"role": "input", "path": str(source), "checksumSHA256": digest(source), "fileSize": source.stat().st_size},
             {"role": "output", "path": str(body), "checksumSHA256": digest(body), "fileSize": body.stat().st_size}]
    (out / "record.json").write_text(json.dumps({"files": files}, indent=2, sort_keys=True) + "\\n")
elif args[0] == "universal-search":
    print("\\n".join(sorted(p.name for p in Path(args[1]).rglob("*") if p.is_dir())))
elif args[:2] == ["ops", "stats"]:
    print("0 operations")
else:
    print("unknown", args, file=sys.stderr)
    sys.exit(2)
'''


def make_cli(folder: Path, change_cell: bool = False, version: str = "2026.1.1", build: str = "12972",
             rewrite_input: bool = False, edit_export: bool = False, tool_dir: str = ".lungfish",
             tool_root: str | None = None, tool_env: str = "samtools") -> Path:
    """tool_dir is the channel folder under the home folder that the exporter expands <tool-root> to,
    tool_root names another root outright and tool_env is the tool environment the exported command names."""
    folder.mkdir(parents=True)
    cli = folder / "lungfish-cli"
    cli.write_text(STAND_IN.replace("PYTHON", sys.executable).replace("CHANGE_FLAG", str(change_cell))
                   .replace("REWRITE_FLAG", str(rewrite_input)).replace("EDIT_FLAG", str(edit_export))
                   .replace("TOOLDIR_TEXT", repr(tool_dir)).replace("TOOLROOT_TEXT", repr(tool_root))
                   .replace("TOOLENV_TEXT", repr(tool_env))
                   .replace("VERSION_TEXT", version).replace("BUILD_TEXT", build))
    cli.chmod(cli.stat().st_mode | stat.S_IXUSR)
    return cli


def make_corpus(root: Path, built_by: Path) -> Path:
    """One release with one project that holds two results, a reference bundle and an analysis.

    Each result's provenance record names the CLI and the build that made the project, as the
    record of a real project does, so an export copies them.
    """
    project = root / "v1.0.0" / "demo" / "Demo.lungfish"
    for result in (project / "Reference Sequences" / "A.lungfishref", project / "Analyses" / "run-1"):
        result.mkdir(parents=True)
        (result / "table.tsv").write_text("gene\tcount\nalpha\t12\nbeta\t20\n")
        (result / "info.json").write_text('{"name": "' + result.name + '", "createdAt": "2026-11-01T10:00:00Z"}\n')
        (result / ".lungfish-provenance.json").write_text(json.dumps(
            {"step": "made", "createdAt": "2026-11-01T10:00:00Z", "builtBy": str(built_by),
             "toolVersion": "Lungfish 2026.1.1 (12972)",
             # A real project stores the placeholder <tool-root>, and an export expands it.
             "argv": ["<tool-root>/envs/samtools/bin/samtools", "faidx", "x.fa"],
             "reproducibleCommand": "<tool-root>/envs/samtools/bin/samtools faidx 'x.fa'"}) + "\n")
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
        self.root = Path(tmp.name).resolve()
        self.corpus = self.root / "corpus"
        self.good = make_cli(self.root / "good")
        self.bad = make_cli(self.root / "bad", change_cell=True)
        self.newer = make_cli(self.root / "newer", version="2026.2.0", build="dev")
        self.project = make_corpus(self.corpus, built_by=self.good)
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

    def test_the_digest_of_a_file_the_export_wrote_does_not_count(self) -> None:
        """The exporter's file holds a random ID, the time and its scratch folder, so its digest changes every run (F1)."""
        for run in range(2):
            code, out, err = run_main("--cli", str(self.good), "--corpus", str(self.corpus))
            self.assertEqual(code, 0, f"run {run + 1}\n{out}{err}")

    def test_a_newer_build_passes_when_only_its_own_identity_changes(self) -> None:
        """The record names the build that made the project (F2) and the build that exports (F3)."""
        code, out, err = run_main("--cli", str(self.newer), "--corpus", str(self.corpus))
        self.assertEqual(code, 0, out + err)
        self.assertIn("0 differences", out)

    def test_an_exported_value_that_changed_is_still_a_difference(self) -> None:
        edited = make_cli(self.root / "edited", edit_export=True)
        code, out, _ = run_main("--cli", str(edited), "--corpus", str(self.corpus))
        self.assertEqual(code, 1, out)
        self.assertTrue(any('"step"' in line and "edited" in line for line in out.splitlines()), out)

    def test_a_changed_checksum_of_an_input_file_is_still_a_difference(self) -> None:
        rewriting = make_cli(self.root / "rewriting", rewrite_input=True)
        code, out, _ = run_main("--cli", str(rewriting), "--corpus", str(self.corpus))
        self.assertEqual(code, 1, out)
        lines = [line for line in out.splitlines() if "checksumSHA256" in line]
        self.assertEqual(len(lines), 2, out)  # the input record of each of the two export steps, not the written file's

    def test_the_tool_root_of_the_exporting_build_does_not_count_on_any_channel(self) -> None:
        """An export expands the stored <tool-root> to the root of its own channel. That names the install (O171)."""
        for channel in (".lungfish-stable", ".lungfish-debug", ".lungfish"):
            cli = make_cli(self.root / f"channel{channel}", tool_dir=channel)
            code, out, err = run_main("--cli", str(cli), "--corpus", str(self.corpus))
            self.assertEqual(code, 0, f"{channel}\n{out}{err}")

    def test_expected_holds_no_home_path_and_the_check_passes_under_another_account(self) -> None:
        """F4: a path under the home folder differs on another Mac, even for the same release."""
        home = str(Path.home())
        for text_file in sorted((self.project.parent / "expected").glob("*.txt")):
            self.assertNotIn(home, text_file.read_text(), text_file.name)
        stable = make_cli(self.root / "stable", tool_dir=".lungfish-stable")
        with mock.patch.object(Path, "home", return_value=Path("/Users/someone-else")):
            code, out, err = run_main("--cli", str(stable), "--corpus", str(self.corpus))
        self.assertEqual(code, 0, out + err)

    def test_a_different_tool_under_the_tool_root_is_still_a_difference(self) -> None:
        other = make_cli(self.root / "other-tool", tool_env="bwa")
        code, out, _ = run_main("--cli", str(other), "--corpus", str(self.corpus))
        self.assertEqual(code, 1, out)
        self.assertTrue(any("envs/bwa/" in line for line in out.splitlines()), out)

    def test_a_tool_root_outside_the_home_folder_is_still_a_difference(self) -> None:
        elsewhere = make_cli(self.root / "elsewhere", tool_root="/usr/local/lib/conda")
        code, out, _ = run_main("--cli", str(elsewhere), "--corpus", str(self.corpus))
        self.assertEqual(code, 1, out)
        self.assertTrue(any("/usr/local/lib/conda" in line for line in out.splitlines()), out)


if __name__ == "__main__":
    unittest.main()
