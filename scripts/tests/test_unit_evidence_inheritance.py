"""Unit-tier evidence follows content.

A passing unit-tier result covers the commit it ran on and any descendant whose
changes all fall under the release-neutral paths of config/release-contract.json
(docs/contracts/VERIFICATION-ORDER.md). These tests build a throwaway git
repository, drop fixture evidence into its .build/gate-logs, and ask
gate_evidence.find_unit_evidence and the unit-evidence command what each commit
inherits.
"""
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from scripts.tests.gate_fixtures import canonical_selection, make_unit_gate_pointer

ROOT = Path(__file__).resolve().parents[2]
GATE_EVIDENCE = ROOT / "scripts/release/gate_evidence.py"
RELEASE = ROOT / "scripts/release/release.py"
CONTRACT = ROOT / "config/release-contract.json"
# The tests that call find_unit_evidence pass this list themselves, so they keep
# their meaning when the shipped list in the contract grows. The command-line
# tests read the contract copied into the throwaway repository instead.
NEUTRAL = ("docs/release-notes/**",)
NOTES = "docs/release-notes/2099.1.1.md"

SPEC = importlib.util.spec_from_file_location("unit_evidence_inheritance_gate", GATE_EVIDENCE)
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)

# The throwaway repositories must not pick up the owner's git configuration
# (signing, hooks path, default branch), which would change what a commit does.
GIT_ENVIRONMENT = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}


class ThrowawayRepository:
    """A real git repository with fixture unit evidence under .build/gate-logs."""

    def __init__(self, case):
        temporary = tempfile.TemporaryDirectory()
        case.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.logs = self.root / ".build" / "gate-logs"
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Evidence Test")
        self.git("config", "user.email", "evidence@example.test")
        self.git("config", "commit.gpgsign", "false")

    def git(self, *arguments):
        return subprocess.run(["git", "-C", str(self.root), *arguments], check=True, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env=GIT_ENVIRONMENT).stdout.strip()

    def commit(self, message, files=None, remove=(), move=()):
        for source, destination in move:
            (self.root / destination).parent.mkdir(parents=True, exist_ok=True)
            self.git("mv", source, destination)
        for relative, text in (files or {}).items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        for relative in remove:
            (self.root / relative).unlink()
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def evidence(self, commit, name, *, clean=True, **options):
        make_unit_gate_pointer(self.root, {"commit": commit, "clean": clean}, name=name, **options)
        return self.logs / name

    def age(self, name, seconds_ago):
        moment = time.time() - seconds_ago
        os.utime(self.logs / name, (moment, moment))


class InheritanceTestCase(unittest.TestCase):
    def setUp(self):
        self.repo = ThrowawayRepository(self)
        # Commit A is the tested code. .build/ is ignored so evidence never
        # dirties the tree, and the real contract lets the CLI read the list.
        self.a = self.repo.commit("A", {
            ".gitignore": ".build/\n",
            "config/release-contract.json": CONTRACT.read_text(),
            "Sources/x.swift": "let x = 1\n",
            "docs/release-notes/a.md": "Notes for A\n",
        })

    def find(self, commit, patterns=NEUTRAL, logs=None):
        return gate.find_unit_evidence(self.repo.root, commit, patterns, logs)


class FindUnitEvidenceTests(InheritanceTestCase):
    def test_release_notes_only_descendant_inherits_the_result(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes for 2099.1.1\n"})

        record = self.find(b)

        self.assertEqual(record["kind"], "inherited")
        self.assertEqual(record["gatedCommit"], self.a)
        self.assertEqual(record["candidateCommit"], b)
        self.assertEqual(record["changedPaths"], [NOTES])
        self.assertEqual(record["releaseNeutralPaths"], list(NEUTRAL))
        result_path = self.repo.logs / "unit-a" / "gate.result.json"
        self.assertEqual(record["resultPath"], str(result_path))
        self.assertEqual(record["resultSha256"], hashlib.sha256(result_path.read_bytes()).hexdigest())
        self.assertEqual(self.repo.git("status", "--porcelain", "--untracked-files=all"), "",
                         "evidence under the ignored .build folder never dirties the tree")

    def test_the_gated_commit_itself_is_covered_exactly(self):
        self.repo.evidence(self.a, "unit-a")

        record = self.find(self.a)

        self.assertEqual(record["kind"], "exact")
        self.assertEqual(record["gatedCommit"], self.a)
        self.assertEqual(record["changedPaths"], [])

    def test_a_code_change_after_the_notes_ends_inheritance(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        c = self.repo.commit("C: notes and code", {NOTES: "More notes\n", "Sources/x.swift": "let x = 2\n"})

        self.assertEqual(self.find(b)["kind"], "inherited")
        self.assertIsNone(self.find(c))

    def test_a_folder_pattern_does_not_cover_a_neighboring_docs_folder(self):
        self.repo.evidence(self.a, "unit-a")
        other_docs = self.repo.commit("Contract text", {"docs/contracts/EXAMPLE.md": "text\n"})

        self.assertIsNone(self.find(other_docs))
        self.assertEqual(self.find(other_docs, patterns=("docs/contracts/**",))["changedPaths"],
                         ["docs/contracts/EXAMPLE.md"])

    def test_nested_release_notes_alone_are_neutral(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("Nested notes", {"docs/release-notes/archive/old.md": "old\n",
                                              NOTES: "Notes\n"})

        record = self.find(b)

        self.assertEqual(record["changedPaths"], [NOTES, "docs/release-notes/archive/old.md"])

    def test_deleting_a_release_note_is_neutral(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("Remove notes", remove=["docs/release-notes/a.md"])

        self.assertEqual(self.find(b)["changedPaths"], ["docs/release-notes/a.md"])

    def test_moving_a_note_out_of_the_neutral_folder_is_not_neutral(self):
        self.repo.evidence(self.a, "unit-a")
        moved = self.repo.commit("Move note into Sources", move=[("docs/release-notes/a.md", "Sources/a.md")])

        self.assertIsNone(self.find(moved))

    def test_moving_source_into_the_neutral_folder_does_not_hide_the_deletion(self):
        # With rename detection a plain name-only diff lists just the new
        # path, so this move would read as a notes-only change.
        self.repo.evidence(self.a, "unit-a")
        moved = self.repo.commit("Hide source in notes",
                                 move=[("Sources/x.swift", "docs/release-notes/x.swift.md")])

        self.assertEqual(self.repo.git("diff", "--name-only", self.a, moved), "docs/release-notes/x.swift.md",
                         "the fixture must be a detected rename for this test to mean anything")
        self.assertIsNone(self.find(moved))

    def test_renaming_within_the_neutral_folder_lists_both_paths(self):
        self.repo.evidence(self.a, "unit-a")
        renamed = self.repo.commit("Rename note", move=[("docs/release-notes/a.md", "docs/release-notes/b.md")])

        record = self.find(renamed)

        self.assertEqual(record["changedPaths"], ["docs/release-notes/a.md", "docs/release-notes/b.md"])

    def test_a_sibling_branch_is_not_a_descendant_of_the_gated_commit(self):
        a1 = self.repo.commit("A1: more code", {"Sources/y.swift": "let y = 1\n"})
        self.repo.git("checkout", "-q", "-b", "side", self.a)
        side = self.repo.commit("S: release notes on the side branch", {NOTES: "Side notes\n"})
        self.repo.evidence(a1, "unit-a1")

        self.assertIsNone(self.find(side))

        self.repo.evidence(self.a, "unit-a")
        record = self.find(side)
        self.assertEqual(record["gatedCommit"], self.a, "ancestry, not similarity, decides what a result covers")
        self.assertEqual(record["changedPaths"], [NOTES])

    def test_a_sibling_whose_paths_differ_only_in_release_notes_is_still_not_covered(self):
        # Every path between the two commits is neutral, but the gated commit is
        # not an ancestor of the candidate, so its result says nothing about it.
        self.repo.git("checkout", "-q", "-b", "side")
        side = self.repo.commit("S: notes on the side branch", {NOTES: "Side notes\n"})
        self.repo.git("checkout", "-q", "main")
        gated = self.repo.commit("G: other notes on main", {"docs/release-notes/2099.1.2.md": "Main notes\n"})
        self.repo.evidence(gated, "unit-g")

        between = self.repo.git("diff", "--name-only", "--no-renames", gated, side).splitlines()
        self.assertEqual(sorted(between), [NOTES, "docs/release-notes/2099.1.2.md"])
        self.assertTrue(all(gate.is_release_neutral(path, NEUTRAL) for path in between))
        self.assertIsNone(self.find(side))

    def test_evidence_on_a_commit_outside_this_repository_covers_nothing(self):
        self.repo.evidence("f" * 40, "unit-elsewhere")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})

        self.assertIsNone(self.find(b))

    def test_exact_evidence_beats_inherited_even_when_it_is_older(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        self.repo.evidence(b, "unit-b")
        self.repo.age("unit-a", 10)
        self.repo.age("unit-b", 1000)

        record = self.find(b)

        self.assertEqual(record["kind"], "exact")
        self.assertEqual(record["gatedCommit"], b)
        self.assertEqual(record["resultPath"], str(self.repo.logs / "unit-b" / "gate.result.json"))
        self.assertEqual(self.find(self.a)["gatedCommit"], self.a)

    def test_the_newest_result_wins_among_inherited_candidates(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        self.repo.evidence(b, "unit-b")
        d = self.repo.commit("D: more release notes", {"docs/release-notes/2099.1.2.md": "More\n"})

        for newer, older, winner, changed in (
            ("unit-b", "unit-a", b, ["docs/release-notes/2099.1.2.md"]),
            ("unit-a", "unit-b", self.a, [NOTES, "docs/release-notes/2099.1.2.md"]),
        ):
            with self.subTest(newer=newer):
                self.repo.age(older, 3600)
                self.repo.age(newer, 60)

                record = self.find(d)

                self.assertEqual(record["kind"], "inherited")
                self.assertEqual(record["gatedCommit"], winner)
                self.assertEqual(record["resultPath"], str(self.repo.logs / newer / "gate.result.json"))
                self.assertEqual(record["changedPaths"], changed)

    def test_an_older_result_covers_when_a_newer_one_cannot(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: code", {"Sources/y.swift": "let y = 1\n"})
        self.repo.evidence(b, "unit-b")
        d = self.repo.commit("D: release notes", {NOTES: "Notes\n"})
        self.repo.age("unit-a", 60)
        self.repo.age("unit-b", 3600)

        # A's result is the newest, but B's code change lies between A and D.
        record = self.find(d)

        self.assertEqual(record["gatedCommit"], b)
        self.assertEqual(record["changedPaths"], [NOTES])

    def test_a_newer_result_on_another_branch_does_not_mask_an_older_one_that_covers(self):
        self.repo.evidence(self.a, "unit-a")
        self.repo.git("checkout", "-q", "-b", "side")
        side = self.repo.commit("S: code on a side branch", {"Sources/side.swift": "let s = 1\n"})
        self.repo.git("checkout", "-q", "main")
        d = self.repo.commit("D: release notes", {NOTES: "Notes\n"})
        self.repo.evidence(side, "unit-side")
        self.repo.age("unit-a", 3600)
        self.repo.age("unit-side", 60)

        self.assertEqual(self.find(d)["gatedCommit"], self.a)

    def test_unauthorized_evidence_is_ignored(self):
        self.repo.evidence(self.a, "unit-a", authorized=False)
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})

        self.assertIsNone(self.find(self.a))
        self.assertIsNone(self.find(b))

    def test_a_result_from_a_dirty_tree_is_ignored(self):
        self.repo.evidence(self.a, "unit-a", clean=False)

        self.assertIsNone(self.find(self.a))

    def test_a_result_that_is_not_the_canonical_unit_selection_is_ignored(self):
        canonical = canonical_selection("unit")
        mutations = {
            "older skip list": {"skip": "OnlyAnOldClass"},
            "empty skip list": {"skip": ""},
            "filtered": {"filter": "ReplayTests"},
            "serial": {"parallel": not canonical["parallel"]},
            "tools required": {"requireTools": not canonical["requireTools"]},
            "other tier": {"tier": "integration"},
        }
        for label, change in mutations.items():
            with self.subTest(label):
                self.repo.evidence(self.a, "unit-a", options={**canonical, **change})
                self.assertIsNone(self.find(self.a))

        self.repo.evidence(self.a, "unit-a")
        self.assertEqual(self.find(self.a)["kind"], "exact", "control: the canonical selection is accepted")

    def test_other_tiers_are_never_unit_evidence(self):
        self.repo.evidence(self.a, "smoke-a", tier="smoke")

        self.assertIsNone(self.find(self.a))

    def test_a_tampered_result_is_ignored(self):
        evidence = self.repo.evidence(self.a, "unit-a")
        result = json.loads((evidence / "gate.result.json").read_text())
        result["errors"] = ["a failure recorded after the fact"]
        (evidence / "gate.result.json").write_text(json.dumps(result))

        self.assertIsNone(self.find(self.a))

    def test_unreadable_results_are_ignored(self):
        broken = self.repo.logs / "unit-broken"
        broken.mkdir(parents=True)
        (broken / "gate.result.json").write_text("{not json")
        (self.repo.logs / "unit-empty").mkdir()
        (self.repo.logs / "unit-array").mkdir()
        (self.repo.logs / "unit-array" / "gate.result.json").write_text("[]")
        self.repo.evidence(self.a, "unit-a")

        self.assertEqual(self.find(self.a)["kind"], "exact")

    def test_a_result_whose_source_names_no_commit_is_skipped_not_fatal(self):
        """validate_result accepts a clean source with no "commit" (same_source
        compares the source with itself), so find_unit_evidence requires a
        full commit before it trusts a result. A damaged folder is skipped
        like every other malformed result."""
        self.repo.evidence(self.a, "unit-a")
        make_unit_gate_pointer(self.repo.root, {"clean": True}, name="unit-no-commit")
        self.repo.age("unit-a", 3600)
        self.repo.age("unit-no-commit", 10)

        self.assertEqual(self.find(self.a)["kind"], "exact")

    def test_symlinked_evidence_is_ignored(self):
        evidence = self.repo.evidence(self.a, "unit-a")
        elsewhere = self.repo.root / ".build" / "elsewhere"
        elsewhere.mkdir()
        moved = elsewhere / "unit-a"
        evidence.rename(moved)

        evidence.symlink_to(moved)
        self.assertIsNone(self.find(self.a), "a symlinked evidence folder")

        evidence.unlink()
        evidence.mkdir()
        (evidence / "gate.result.json").symlink_to(moved / "gate.result.json")
        self.assertIsNone(self.find(self.a), "a symlinked result file")

        (evidence / "gate.result.json").unlink()
        shutil.copytree(moved, evidence, dirs_exist_ok=True)
        self.assertEqual(self.find(self.a)["kind"], "exact", "control: the same bytes in a real folder")

    def test_missing_or_empty_logs_find_nothing(self):
        self.assertIsNone(self.find(self.a))
        self.repo.logs.mkdir(parents=True)
        self.assertIsNone(self.find(self.a))

    def test_an_explicit_logs_folder_replaces_the_default(self):
        self.repo.evidence(self.a, "unit-a")
        elsewhere = self.repo.root / "other-logs"
        elsewhere.mkdir()

        self.assertIsNone(self.find(self.a, logs=elsewhere))
        self.assertEqual(self.find(self.a, logs=self.repo.logs)["kind"], "exact")

    def test_a_gate_folder_named_for_another_commit_is_not_trusted(self):
        stamp = "gate-20261007-120000-"
        genuine = self.repo.evidence(self.a, f"{stamp}{self.a[:9]}-4242")
        self.assertEqual(self.find(self.a)["kind"], "exact", "a folder named like full-suite-gate.sh names it")

        genuine.rename(genuine.with_name(f"{stamp}deadbeef0-4242"))
        self.assertIsNone(self.find(self.a), "a folder whose name disagrees with the candidate history")

    def test_no_patterns_means_no_inheritance(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})

        self.assertIsNone(self.find(b, patterns=()))
        self.assertEqual(self.find(self.a, patterns=())["kind"], "exact")


class ReleaseNeutralPathTests(unittest.TestCase):
    def test_folder_pattern_matches_nested_files_only(self):
        patterns = ("docs/release-notes/**",)
        cases = {
            "docs/release-notes/2099.1.1.md": True,
            "docs/release-notes/archive/old/2020.1.1.md": True,
            "docs/release-notes-old/x.md": False,
            "docs/release-notes": False,
            "docs/release-notesx/x.md": False,
            "docs/release/notes/x.md": False,
            "docs/other.md": False,
            "Sources/docs/release-notes/x.md": False,
            "xdocs/release-notes/x.md": False,
            "": False,
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertIs(gate.is_release_neutral(path, patterns), expected)

    def test_exact_file_pattern_matches_only_itself(self):
        patterns = ("docs/contracts/EXAMPLE.md",)
        cases = {
            "docs/contracts/EXAMPLE.md": True,
            "docs/contracts/EXAMPLE.md.bak": False,
            "docs/contracts/EXAMPLE.md/inner.md": False,
            "docs/contracts/EXAMPLE.mdx": False,
            "docs/contracts/OTHER.md": False,
            "docs/contracts": False,
            "other/docs/contracts/EXAMPLE.md": False,
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertIs(gate.is_release_neutral(path, patterns), expected)

    def test_any_one_pattern_is_enough_and_none_matches_nothing(self):
        patterns = ("docs/release-notes/**", "docs/contracts/EXAMPLE.md")

        self.assertTrue(gate.is_release_neutral("docs/release-notes/a.md", patterns))
        self.assertTrue(gate.is_release_neutral("docs/contracts/EXAMPLE.md", patterns))
        self.assertFalse(gate.is_release_neutral("docs/contracts/OTHER.md", patterns))
        self.assertFalse(gate.is_release_neutral("docs/release-notes/a.md", ()))


class NeutralDeltaTests(InheritanceTestCase):
    def test_same_commit_has_an_empty_delta(self):
        self.assertEqual(gate.neutral_delta(self.repo.root, self.a, self.a, NEUTRAL), [])

    def test_paths_are_sorted_and_all_listed(self):
        b = self.repo.commit("B", {"docs/release-notes/z.md": "z\n", "docs/release-notes/b.md": "b\n"})

        self.assertEqual(gate.neutral_delta(self.repo.root, self.a, b, NEUTRAL),
                         ["docs/release-notes/b.md", "docs/release-notes/z.md"])

    def test_the_candidate_must_descend_from_the_ancestor(self):
        b = self.repo.commit("B", {NOTES: "Notes\n"})

        self.assertIsNone(gate.neutral_delta(self.repo.root, b, self.a, NEUTRAL), "backwards")
        self.assertIsNone(gate.neutral_delta(self.repo.root, "f" * 40, b, NEUTRAL), "unknown ancestor")

    def test_any_non_neutral_path_voids_the_delta(self):
        b = self.repo.commit("B", {NOTES: "Notes\n", "Package.swift": "// swift\n"})

        self.assertIsNone(gate.neutral_delta(self.repo.root, self.a, b, NEUTRAL))


class UnitEvidenceCommandTests(InheritanceTestCase):
    def run_command(self, *commits, logs=True):
        command = [sys.executable, str(GATE_EVIDENCE), "unit-evidence", "--root", str(self.repo.root)]
        for commit in commits:
            command += ["--commit", commit]
        if logs:
            command += ["--logs", str(self.repo.logs)]
        return subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, check=False)

    def test_the_list_is_read_from_the_root_contract(self):
        listed = tuple(json.loads(CONTRACT.read_text())["gates"]["releaseNeutralPaths"])

        self.assertEqual(gate.release_neutral_patterns(self.repo.root), listed)
        self.assertEqual(gate.release_neutral_patterns(ROOT), listed)
        self.assertIn("docs/release-notes/**", listed)

    def test_an_inheriting_commit_exits_zero_and_says_inherited(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})

        result = self.run_command(b)

        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(len(lines), 1, result.stdout)
        self.assertTrue(lines[0].startswith("inherited"), lines[0])
        self.assertIn(f"{b} from {self.a}", lines[0])
        self.assertIn("(1 release-neutral paths)", lines[0])
        self.assertTrue(lines[0].endswith(str(self.repo.logs / "unit-a" / "gate.result.json")), lines[0])

    def test_a_code_change_exits_one_and_says_none(self):
        self.repo.evidence(self.a, "unit-a")
        self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        c = self.repo.commit("C: code", {"Sources/x.swift": "let x = 3\n"})

        result = self.run_command(c)

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), [f"none {c}"])

    def test_the_gated_commit_says_exact_with_the_result_path(self):
        self.repo.evidence(self.a, "unit-a")

        result = self.run_command(self.a)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         [f"exact {self.a} {self.repo.logs / 'unit-a' / 'gate.result.json'}"])

    def test_every_named_commit_must_be_covered(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        c = self.repo.commit("C: code", {"Sources/x.swift": "let x = 3\n"})

        result = self.run_command(b, c)

        self.assertEqual(result.returncode, 1, result.stderr)
        first, second = result.stdout.splitlines()
        self.assertTrue(first.startswith("inherited"), first)
        self.assertEqual(second, f"none {c}")
        self.assertEqual(self.run_command(self.a, b).returncode, 0)

    def test_refs_are_resolved_and_unknown_commits_are_none_without_a_traceback(self):
        self.repo.evidence(self.a, "unit-a")
        unknown = "0123456789abcdef0123456789abcdef01234567"

        by_ref = self.run_command("HEAD")
        missing = self.run_command(unknown)

        self.assertEqual(by_ref.returncode, 0, by_ref.stderr)
        self.assertTrue(by_ref.stdout.startswith(f"exact {self.a} "), by_ref.stdout)
        self.assertEqual(missing.returncode, 1)
        self.assertEqual(missing.stdout.splitlines(), [f"none {unknown}"])
        self.assertEqual(missing.stderr, "")

    def test_the_default_logs_folder_is_under_the_root(self):
        self.repo.evidence(self.a, "unit-a")

        result = self.run_command(self.a, logs=False)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("exact"), result.stdout)

    def test_the_list_comes_from_the_root_contract(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        contract = json.loads(CONTRACT.read_text())
        contract["gates"].pop("releaseNeutralPaths")
        (self.repo.root / "config/release-contract.json").write_text(json.dumps(contract))

        without_list = self.run_command(b)
        exact = self.run_command(self.a)

        self.assertEqual(without_list.returncode, 1, without_list.stderr)
        self.assertEqual(without_list.stdout.splitlines(), [f"none {b}"])
        self.assertEqual(exact.returncode, 0, "exact evidence needs no list")

    def test_a_missing_contract_fails_cleanly(self):
        self.repo.evidence(self.a, "unit-a")
        (self.repo.root / "config/release-contract.json").unlink()

        result = self.run_command(self.a)

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Traceback", result.stderr)

    def test_at_least_one_commit_is_required(self):
        result = self.run_command()

        self.assertEqual(result.returncode, 2)
        self.assertIn("--commit", result.stderr)


class ReleasePreconditionInheritanceTests(InheritanceTestCase):
    """release.py reaches the same evidence through verify_unit_gate_precondition."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("release_unit_evidence_inheritance", RELEASE)
        cls.release = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = cls.release
        spec.loader.exec_module(cls.release)

    def test_a_release_notes_commit_is_covered_when_the_contract_list_is_passed(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        source = {"commit": b, "clean": True}

        record = self.release.verify_unit_gate_precondition(self.repo.root, source, NEUTRAL)

        self.assertEqual((record["kind"], record["gatedCommit"], record["changedPaths"]),
                         ("inherited", self.a, [NOTES]))
        with self.assertRaisesRegex(self.release.ReleaseError, "no unit-tier gate evidence covers"):
            self.release.verify_unit_gate_precondition(self.repo.root, source)

    def test_a_code_commit_is_refused_even_with_the_contract_list(self):
        self.repo.evidence(self.a, "unit-a")
        code = self.repo.commit("B: code", {"Sources/x.swift": "let x = 9\n"})

        with self.assertRaisesRegex(self.release.ReleaseError, "no unit-tier gate evidence covers"):
            self.release.verify_unit_gate_precondition(self.repo.root, {"commit": code, "clean": True}, NEUTRAL)


if __name__ == "__main__":
    unittest.main()
