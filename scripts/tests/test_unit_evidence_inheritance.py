"""Unit-tier evidence follows content.

A passing unit-tier result covers the commit it ran on and any descendant whose
changes all fall under the release-neutral paths of config/release-contract.json
(docs/contracts/VERIFICATION-ORDER.md). A failing canonical run is evidence too.
The newest run on a commit decides that commit, and a failed commit between the
covering ancestor and the candidate stops the inheritance. These tests build a
throwaway git repository, drop fixture evidence into its .build/gate-logs, and
ask gate_evidence.find_unit_evidence and the unit-evidence command what each
commit inherits.
"""
import contextlib
import copy
import hashlib
import importlib.util
import io
import itertools
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

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
# Every record find_unit_evidence returns, whatever its kind, carries exactly these fields.
RECORD_KEYS = {"schemaVersion", "kind", "candidateCommit", "gatedCommit", "resultPath", "resultSha256",
               "changedPaths", "releaseNeutralPaths"}

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

    def edit(self, name, change):
        """Rewrite a retained result the way a different kind of run would have left it."""
        path = self.logs / name / "gate.result.json"
        result = json.loads(path.read_text())
        change(result)
        path.write_text(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n")

    def edit_in(self, root, name, change):
        path = root / ".build" / "gate-logs" / name / "gate.result.json"
        result = json.loads(path.read_text())
        change(result)
        path.write_text(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n")

    def age(self, name, seconds_ago):
        """The newest result on a commit decides it, ordered by the mtime of its
        gate.result.json, so that file's time is the one that matters."""
        moment = time.time() - seconds_ago
        for path in (self.logs / name / "gate.result.json", self.logs / name):
            os.utime(path, (moment, moment))

    def result_path(self, name):
        return self.logs / name / "gate.result.json"

    def reset_logs(self):
        shutil.rmtree(self.logs, ignore_errors=True)

    def linked_worktree(self, case, commit):
        """Another worktree of the same repository, checked out at commit. A
        lane or program worktree keeps its own .build/gate-logs."""
        temporary = tempfile.TemporaryDirectory()
        case.addCleanup(temporary.cleanup)
        path = Path(temporary.name).resolve() / "linked"
        self.git("worktree", "add", "-q", "--detach", str(path), commit)
        return path


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

    def notes(self, number, parent_message="release notes"):
        """A commit that changes release notes only, so it is neutral to its parent."""
        return self.repo.commit(f"{parent_message} {number}",
                                {f"docs/release-notes/2099.1.{number}.md": f"Notes {number}\n"})

    def code(self, number):
        """A commit that changes Swift source, so no result before it covers what follows."""
        return self.repo.commit(f"code {number}", {"Sources/x.swift": f"let x = {number}\n"})


class FindUnitEvidenceTests(InheritanceTestCase):
    def test_release_notes_only_descendant_inherits_the_result(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes for 2099.1.1\n"})

        record = self.find(b)

        self.assertEqual(set(record), RECORD_KEYS)
        self.assertEqual(record["schemaVersion"], 1)
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

        self.assertEqual(set(record), RECORD_KEYS)
        self.assertEqual(record["schemaVersion"], 1)
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

    def test_the_nearest_ancestor_decides_whatever_the_result_times(self):
        # The nearest ancestor that shares the candidate's code decides, not
        # the newest result file: B is nearer to D than A in both cases.
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        self.repo.evidence(b, "unit-b")
        d = self.repo.commit("D: more release notes", {"docs/release-notes/2099.1.2.md": "More\n"})

        for newer, older, winner, changed in (
            ("unit-b", "unit-a", b, ["docs/release-notes/2099.1.2.md"]),
            ("unit-a", "unit-b", b, ["docs/release-notes/2099.1.2.md"]),
        ):
            with self.subTest(newer=newer):
                self.repo.age(older, 3600)
                self.repo.age(newer, 60)

                record = self.find(d)

                self.assertEqual(record["kind"], "inherited")
                self.assertEqual(record["gatedCommit"], winner)
                self.assertEqual(record["resultPath"], str(self.repo.logs / "unit-b" / "gate.result.json"))
                self.assertEqual(record["changedPaths"], changed)

    def test_release_notes_on_a_failed_commit_are_red_even_without_a_green_ancestor(self):
        b = self.repo.commit("B: code", {"Sources/y.swift": "let y = 1\n"})
        self.repo.evidence(b, "unit-b", authorized=False)
        c = self.repo.commit("C: release notes", {NOTES: "Notes\n"})

        record = self.find(c)

        self.assertEqual((record["kind"], record["gatedCommit"]), ("red", b))

    def test_a_nearer_green_ancestor_covers_past_an_older_failure(self):
        # A green (newest file), B red, C green, D notes on C: C decides.
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        self.repo.evidence(b, "unit-b", authorized=False)
        c = self.repo.commit("C: more release notes", {"docs/release-notes/2099.1.2.md": "More\n"})
        self.repo.evidence(c, "unit-c")
        d = self.repo.commit("D: release notes again", {"docs/release-notes/2099.1.3.md": "Again\n"})
        self.repo.age("unit-b", 7200)
        self.repo.age("unit-c", 3600)
        self.repo.age("unit-a", 60)

        record = self.find(d)

        self.assertEqual((record["kind"], record["gatedCommit"]), ("inherited", c))

    def test_a_failure_on_code_that_was_reverted_does_not_reach_the_revert(self):
        # B changes code and fails; C reverts it and adds notes, so C shares A's code.
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: code", {"Sources/y.swift": "let y = 1\n"})
        self.repo.evidence(b, "unit-b", authorized=False)
        self.repo.git("rm", "-q", "Sources/y.swift")
        c = self.repo.commit("C: revert B and add notes", {NOTES: "Notes\n"})

        record = self.find(c)

        self.assertEqual((record["kind"], record["gatedCommit"]), ("inherited", self.a))

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

    def test_a_failed_canonical_run_never_covers_anything(self):
        evidence = self.repo.evidence(self.a, "unit-a", authorized=False)
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})

        record = self.find(self.a)

        self.assertEqual(record["kind"], "red", "a failure is reported, not ignored")
        self.assertEqual((record["candidateCommit"], record["gatedCommit"]), (self.a, self.a))
        self.assertEqual(record["resultPath"], str(evidence / "gate.result.json"))
        self.assertEqual(record["resultSha256"], hashlib.sha256((evidence / "gate.result.json").read_bytes()).hexdigest())
        self.assertEqual(record["changedPaths"], [])
        covering = {"exact", "inherited"}
        self.assertNotIn((self.find(b) or {}).get("kind"), covering,
                         "a failed run covers neither itself nor a descendant")

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


WATCHDOG_COMMAND = {"argv": ["swift", "test"], "exitStatus": 15, "intervention": "timeout", "files": []}

# What a failed run looks like when the failure says nothing about the code:
# the watchdog stepped in on one of its commands, or the checkout changed
# while it ran. Each entry edits a retained result in place.
UNINFORMATIVE_FAILURES = {
    "the watchdog stopped the identity command": lambda r: r["identityCommand"].update(intervention="timeout"),
    "the watchdog stopped the SDK command": lambda r: r["sdkCommand"].update(intervention="timeout"),
    "the watchdog stopped a discovery command": lambda r: r.update(discovery=[WATCHDOG_COMMAND]),
    "the watchdog stopped the test attempt": lambda r: r["attempts"][0].update(
        intervention="terminated-unreaped-xctest-parent"),
    "the checkout changed during the run": lambda r: r.update(errors=["source changed during gate"]),
    "the checkout changed among other errors": lambda r: r.update(
        errors=["empty test selection", "source changed during gate"]),
}


class RedEvidenceTests(InheritanceTestCase):
    """A failed canonical run is recorded as "red" for its commit and, through
    release-neutral paths, for the descendants a green ancestor would otherwise
    cover. Only failures that describe the code count."""

    def test_a_watchdog_on_a_diagnostic_retry_never_hides_a_real_failure(self):
        # The authoritative attempt failed; only the isolated retry of the
        # failing class needed the watchdog. The failure still describes the code.
        self.repo.evidence(self.a, "unit-a-green")
        self.repo.evidence(self.a, "unit-a-red", authorized=False)
        self.repo.edit("unit-a-red", lambda r: r["attempts"].append(
            {**r["attempts"][0], "role": "diagnostic-retry", "intervention": "timeout"}))
        self.repo.age("unit-a-green", 3600)
        self.repo.age("unit-a-red", 60)

        self.assertEqual(self.find(self.a)["kind"], "red")

    def test_a_failure_wins_a_tie_on_result_time(self):
        self.repo.evidence(self.a, "unit-a-green")
        self.repo.evidence(self.a, "unit-a-red", authorized=False)
        self.repo.age("unit-a-green", 600)
        self.repo.age("unit-a-red", 600)

        self.assertEqual(self.find(self.a)["kind"], "red")

    def assert_red(self, record, *, candidate, gated, name):
        self.assertIsNotNone(record, "a failed run is reported, never silently ignored")
        self.assertEqual(record["kind"], "red")
        self.assertEqual(set(record), RECORD_KEYS)
        self.assertEqual(record["schemaVersion"], 1)
        self.assertEqual((record["candidateCommit"], record["gatedCommit"]), (candidate, gated))
        path = self.repo.result_path(name)
        self.assertEqual(record["resultPath"], str(path))
        self.assertEqual(record["resultSha256"], hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(record["releaseNeutralPaths"], list(NEUTRAL))

    def test_a_failed_canonical_run_on_the_commit_is_red_with_every_field(self):
        self.repo.evidence(self.a, "unit-a", authorized=False)

        record = self.find(self.a)

        self.assert_red(record, candidate=self.a, gated=self.a, name="unit-a")
        self.assertEqual(record["changedPaths"], [])

    def test_the_newest_run_on_a_commit_decides_it_and_what_it_covers(self):
        b = self.notes(10)  # a release-notes commit on top of A
        cases = (
            ("a failed run after the passing one", 3600, 60, "red", "unit-red", False),
            ("a passing rerun after the failed one", 60, 3600, "exact", "unit-green", True),
        )
        for label, green_age, red_age, kind, winner, covers_descendants in cases:
            with self.subTest(label):
                self.repo.reset_logs()
                self.repo.evidence(self.a, "unit-green")
                self.repo.evidence(self.a, "unit-red", authorized=False)
                self.repo.age("unit-green", green_age)
                self.repo.age("unit-red", red_age)

                record = self.find(self.a)
                descendant = self.find(b)

                self.assertEqual(record["kind"], kind)
                self.assertEqual(record["gatedCommit"], self.a)
                self.assertEqual(record["resultPath"], str(self.repo.result_path(winner)))
                if covers_descendants:
                    self.assertEqual((descendant["kind"], descendant["gatedCommit"]), ("inherited", self.a))
                    self.assertEqual(descendant["resultPath"], str(self.repo.result_path("unit-green")))
                else:
                    self.assertNotIn((descendant or {}).get("kind"), {"exact", "inherited"},
                                     "an older pass on A does not cover B once A's newest run failed")

    def test_a_failed_run_between_the_green_ancestor_and_the_candidate_is_red(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.notes(10)
        self.repo.evidence(b, "unit-b", authorized=False)
        c = self.notes(11)
        d = self.notes(12)

        # The green run on A would cover C and D through release-neutral paths,
        # but B between them failed, so the failure is what they inherit.
        self.assert_red(self.find(c), candidate=c, gated=b, name="unit-b")
        self.assert_red(self.find(d), candidate=d, gated=b, name="unit-b")
        self.assert_red(self.find(b), candidate=b, gated=b, name="unit-b")
        self.assertEqual(self.find(self.a)["kind"], "exact", "the commit before the failure is still covered")

    def test_a_newer_passing_run_on_the_failed_commit_lifts_the_block(self):
        # (label, age of A's run, age of B's rerun, whose run the answer names, note numbers)
        cases = (
            ("B's passing rerun is the newest green run", 7200, 60, "unit-b-green", (10, 11)),
            # B is nearer to C than A, so B's green rerun covers C even when
            # A's result file is newer.
            ("A's run is the newer result file", 60, 1800, "unit-b-green", (12, 13)),
        )
        for label, a_age, b_green_age, winner, numbers in cases:
            with self.subTest(label):
                self.repo.reset_logs()
                self.repo.evidence(self.a, "unit-a")
                self.repo.git("checkout", "-q", "-B", "work", self.a)
                b = self.notes(numbers[0])
                self.repo.evidence(b, "unit-b-red", authorized=False)
                c = self.notes(numbers[1])
                self.assertEqual(self.find(c)["kind"], "red", "control: the failure blocks C")
                self.repo.evidence(b, "unit-b-green")
                self.repo.age("unit-a", a_age)
                self.repo.age("unit-b-red", 3600)
                self.repo.age("unit-b-green", b_green_age)

                record = self.find(c)

                self.assertEqual(record["kind"], "inherited", "B's newest run is green now, so it blocks nothing")
                self.assertEqual(record["resultPath"], str(self.repo.result_path(winner)))
                self.assertEqual(record["gatedCommit"], b if winner == "unit-b-green" else self.a)

    def test_a_failed_run_off_the_candidates_history_does_not_block_it(self):
        self.repo.evidence(self.a, "unit-a")
        self.repo.git("checkout", "-q", "-b", "side")
        side = self.notes(20, "side notes")
        self.repo.evidence(side, "unit-side", authorized=False)
        self.repo.git("checkout", "-q", "main")
        b = self.notes(21)

        record = self.find(b)

        self.assertEqual((record["kind"], record["gatedCommit"]), ("inherited", self.a))
        self.assertEqual(self.find(side)["kind"], "red", "control: the side branch itself failed")

    def test_a_fix_after_a_failed_run_is_not_blocked_by_it(self):
        self.repo.evidence(self.a, "unit-a")
        broken = self.code(2)
        self.repo.evidence(broken, "unit-broken", authorized=False)
        fix = self.code(3)
        notes_on_fix = self.notes(30)

        # New code is a new commit. The failure on the old code must not refuse it,
        # and no earlier green run covers it either, so the answer is "nothing yet".
        self.assertEqual(self.find(broken)["kind"], "red")
        self.assertIsNone(self.find(fix))
        self.assertIsNone(self.find(notes_on_fix))

    def test_an_old_failure_before_the_covering_commit_does_not_block_what_follows(self):
        # The real flow: the code fails, a fix passes the unit tier, then the release notes
        # are committed on top of the fix. The old failure is history, not a verdict on them.
        self.repo.evidence(self.a, "unit-a")
        broken = self.code(2)
        self.repo.evidence(broken, "unit-broken", authorized=False)
        fix = self.code(3)
        self.repo.evidence(fix, "unit-fix")
        release_notes = self.notes(30)

        record = self.find(release_notes)

        self.assertEqual((record["kind"], record["gatedCommit"]), ("inherited", fix))
        self.assertEqual(record["resultPath"], str(self.repo.result_path("unit-fix")))
        self.assertEqual(record["changedPaths"], ["docs/release-notes/2099.1.30.md"])
        self.assertEqual(self.find(fix)["kind"], "exact")
        self.assertEqual(self.find(broken)["kind"], "red", "control: the old failure is still recorded")

    def test_failures_that_say_nothing_about_the_code_are_ignored(self):
        for label, change in UNINFORMATIVE_FAILURES.items():
            with self.subTest(label):
                self.repo.reset_logs()
                self.repo.evidence(self.a, "unit-a", authorized=False)
                self.repo.edit("unit-a", change)

                self.assertIsNone(self.find(self.a))

        with self.subTest("control: an ordinary failure is red"):
            self.repo.reset_logs()
            self.repo.evidence(self.a, "unit-a", authorized=False)
            self.repo.edit("unit-a", lambda result: result.update(errors=["empty test selection"]))

            self.assertEqual(self.find(self.a)["kind"], "red")

    def test_a_failure_that_says_nothing_about_the_code_does_not_mask_a_passing_run(self):
        for label, change in UNINFORMATIVE_FAILURES.items():
            with self.subTest(label):
                self.repo.reset_logs()
                self.repo.evidence(self.a, "unit-green")
                self.repo.evidence(self.a, "unit-interrupted", authorized=False)
                self.repo.edit("unit-interrupted", change)
                self.repo.age("unit-green", 3600)
                self.repo.age("unit-interrupted", 60)

                record = self.find(self.a)

                self.assertEqual(record["kind"], "exact")
                self.assertEqual(record["resultPath"], str(self.repo.result_path("unit-green")))

    def test_a_failed_run_that_is_not_a_canonical_clean_unit_run_is_ignored(self):
        canonical = canonical_selection("unit")
        cases = {
            "older skip list": {"options": {**canonical, "skip": "OnlyAnOldClass"}},
            "empty skip list": {"options": {**canonical, "skip": ""}},
            "filtered": {"options": {**canonical, "filter": "ReplayTests"}},
            "serial": {"options": {**canonical, "parallel": not canonical["parallel"]}},
            "tools required": {"options": {**canonical, "requireTools": not canonical["requireTools"]}},
            "another tier": {"tier": "integration"},
            "smoke tier": {"tier": "smoke"},
            "dirty tree": {"clean": False},
        }
        for label, change in cases.items():
            with self.subTest(label):
                self.repo.reset_logs()
                self.repo.evidence(self.a, "unit-a", authorized=False, **change)

                self.assertIsNone(self.find(self.a))

        with self.subTest("not a swift run"):
            self.repo.reset_logs()
            self.repo.evidence(self.a, "unit-a", authorized=False)
            self.repo.edit("unit-a", lambda result: result.update(kind="python-unittest"))

            self.assertIsNone(self.find(self.a))

        with self.subTest("control: the canonical selection on a clean tree is red"):
            self.repo.reset_logs()
            self.repo.evidence(self.a, "unit-a", authorized=False)

            self.assertEqual(self.find(self.a)["kind"], "red")

    def test_a_failed_run_that_is_not_canonical_does_not_mask_a_passing_run(self):
        self.repo.evidence(self.a, "unit-green")
        self.repo.evidence(self.a, "unit-filtered", authorized=False,
                           options={**canonical_selection("unit"), "filter": "ReplayTests"})
        self.repo.evidence(self.a, "unit-dirty", authorized=False, clean=False)
        self.repo.age("unit-green", 3600)
        self.repo.age("unit-filtered", 60)
        self.repo.age("unit-dirty", 30)

        self.assertEqual(self.find(self.a)["kind"], "exact")

    def test_a_run_that_claims_to_pass_but_does_not_validate_is_neither_green_nor_red(self):
        mutations = {
            "an error was recorded": lambda result: result.update(errors=["a failure recorded after the fact"]),
            "the watchdog stepped in": lambda result: result["attempts"][0].update(intervention="timeout"),
            "the authoritative attempt failed": lambda result: result["attempts"][0].update(passed=False),
            "the authoritative attempt exited nonzero": lambda result: result["attempts"][0].update(exitStatus=1),
            "the SDK selection did not pass": lambda result: result["sdkCommand"].update(exitStatus=1),
        }
        for label, change in mutations.items():
            with self.subTest(label):
                self.repo.reset_logs()
                self.repo.evidence(self.a, "unit-a")
                self.repo.edit("unit-a", change)

                self.assertIsNone(self.find(self.a))

    def test_a_malformed_failed_result_is_skipped_not_fatal(self):
        malformed = {
            "discovery is not a list": lambda result: result.update(discovery=None),
            "errors is not a list": lambda result: result.update(errors=None),
            "options is not an object": lambda result: result.update(options=["unit"]),
            "source is not an object": lambda result: result.update(source="a commit"),
        }
        for label, change in malformed.items():
            with self.subTest(label):
                self.repo.reset_logs()
                self.repo.evidence(self.a, "unit-a", authorized=False)
                self.repo.edit("unit-a", change)
                self.repo.evidence(self.a, "unit-old-green")
                self.repo.age("unit-a", 60)
                self.repo.age("unit-old-green", 3600)

                self.assertEqual(self.find(self.a)["kind"], "exact", "the broken file is passed over")

    def test_every_worktrees_gate_logs_are_searched_unless_a_folder_is_named(self):
        linked = self.repo.linked_worktree(self, self.a)
        make_unit_gate_pointer(linked, {"commit": self.a, "clean": True}, name="unit-linked")
        b = self.notes(10)
        result = linked / ".build" / "gate-logs" / "unit-linked" / "gate.result.json"

        exact = self.find(self.a)
        inherited = self.find(b)

        self.assertEqual((exact["kind"], exact["resultPath"]), ("exact", str(result)))
        self.assertEqual((inherited["kind"], inherited["gatedCommit"], inherited["resultPath"]),
                         ("inherited", self.a, str(result)))
        self.assertIsNone(self.find(self.a, logs=self.repo.logs), "one named folder replaces the search")
        self.assertEqual(self.find(self.a, logs=linked / ".build" / "gate-logs")["kind"], "exact")

    def test_the_newest_run_decides_across_worktrees(self):
        linked = self.repo.linked_worktree(self, self.a)
        self.repo.evidence(self.a, "unit-green")
        make_unit_gate_pointer(linked, {"commit": self.a, "clean": True}, name="unit-red", authorized=False)
        red = linked / ".build" / "gate-logs" / "unit-red" / "gate.result.json"

        def stamp(green_seconds_ago, red_seconds_ago):
            self.repo.age("unit-green", green_seconds_ago)
            moment = time.time() - red_seconds_ago
            os.utime(red, (moment, moment))

        stamp(3600, 60)
        record = self.find(self.a)
        self.assertEqual((record["kind"], record["resultPath"]), ("red", str(red)))

        stamp(60, 3600)
        self.assertEqual(self.find(self.a)["kind"], "exact")


class UnitResultStatusTests(unittest.TestCase):
    """The one predicate that inheritance and the red rule share."""

    @classmethod
    def setUpClass(cls):
        cls.expected = gate.canonical_tier_options("unit", False)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        make_unit_gate_pointer(root, {"commit": "a" * 40, "clean": True}, name="green")
        self.green = json.loads((root / ".build/gate-logs/green/gate.result.json").read_text())

    def status(self, change=None, *, authorized=True, expected=None):
        result = copy.deepcopy(self.green)
        result["authorized"] = authorized
        if change is not None:
            change(result)
        return gate.unit_result_status(result, self.expected if expected is None else expected)

    def test_a_valid_authorized_canonical_clean_unit_run_is_green(self):
        self.assertEqual(self.status(), "green")

    def test_an_unauthorized_canonical_clean_unit_run_is_red(self):
        self.assertEqual(self.status(authorized=False), "red")
        self.assertEqual(self.status(lambda r: r.update(errors=["empty test selection"]), authorized=False), "red")
        self.assertEqual(self.status(lambda r: r["attempts"][0].update(passed=False, exitStatus=1), authorized=False),
                         "red")

    def test_failures_that_say_nothing_about_the_code_are_not_red(self):
        for label, change in UNINFORMATIVE_FAILURES.items():
            with self.subTest(label):
                self.assertIsNone(self.status(change, authorized=False))

    def test_an_authorized_result_must_validate_to_be_green(self):
        self.assertIsNone(self.status(lambda r: r.update(errors=["tampered"])))
        self.assertIsNone(self.status(lambda r: r["attempts"][0].update(intervention="timeout")))
        self.assertIsNone(self.status(lambda r: r.update(schemaVersion=2)))

    def test_only_a_swift_unit_tier_run_counts(self):
        self.assertIsNone(self.status(lambda r: r.update(kind="python-unittest"), authorized=False))
        self.assertIsNone(self.status(lambda r: r.update(kind=None), authorized=False))
        self.assertIsNone(self.status(lambda r: r["options"].update(tier="integration"), authorized=False))
        self.assertIsNone(self.status(lambda r: r["options"].pop("tier"), authorized=False))
        for bad in (None, ["unit"], "unit"):
            with self.subTest(options=bad):
                self.assertIsNone(self.status(lambda r, bad=bad: r.update(options=bad), authorized=False))

    def test_the_options_must_equal_the_expected_selection(self):
        for key in self.expected:
            with self.subTest(key=key):
                self.assertIsNone(self.status(lambda r, key=key: r["options"].update({key: "changed"}), authorized=False))
                self.assertIsNone(self.status(lambda r, key=key: r["options"].pop(key), authorized=False))
        self.assertIsNone(self.status(authorized=False, expected={**self.expected, "skip": "another list"}))
        self.assertIsNone(self.status(expected={**self.expected, "skip": "another list"}))

    def test_the_source_must_be_clean_and_name_a_full_commit(self):
        self.assertIsNone(self.status(lambda r: r["source"].update(clean=False), authorized=False))
        self.assertIsNone(self.status(lambda r: r["source"].pop("clean"), authorized=False))
        self.assertIsNone(self.status(lambda r: r["source"].update(clean="yes"), authorized=False))
        for commit in ("", "a" * 39, "a" * 41, "A" * 40, "g" * 40, None):
            with self.subTest(commit=commit):
                self.assertIsNone(self.status(lambda r, commit=commit: r["source"].update(commit=commit), authorized=False))
        self.assertIsNone(self.status(lambda r: r["source"].pop("commit"), authorized=False))
        self.assertIsNone(self.status(lambda r: r.update(source="a" * 40), authorized=False))
        self.assertIsNone(self.status(lambda r: r.pop("source"), authorized=False))


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

    def test_a_red_commit_exits_three_and_names_the_commit_and_result_that_failed(self):
        self.repo.evidence(self.a, "unit-a", authorized=False)

        result = self.run_command(self.a)

        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         [f"red {self.a} failed on {self.a} {self.repo.result_path('unit-a')}"])
        self.assertEqual(result.stderr, "")
        by_ref = self.run_command("HEAD")
        self.assertEqual((by_ref.returncode, by_ref.stdout), (3, result.stdout), "a ref is reported as the full commit")

    def test_a_descendant_of_a_failed_commit_names_the_commit_that_failed_not_itself(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.notes(10)
        self.repo.evidence(b, "unit-b", authorized=False)
        c = self.notes(11)
        failed = self.repo.result_path("unit-b")

        result = self.run_command(self.a, b, c)

        self.assertEqual(result.returncode, 3, result.stderr)
        covered, red_b, red_c = result.stdout.splitlines()
        self.assertTrue(covered.startswith(f"exact {self.a} "), covered)
        self.assertEqual(red_b, f"red {b} failed on {b} {failed}")
        self.assertEqual(red_c, f"red {c} failed on {b} {failed}")
        self.assertEqual(self.run_command(self.a).returncode, 0, "the commit before the failure is still covered")

    def test_a_failure_that_says_nothing_about_the_code_is_reported_as_none_not_red(self):
        self.repo.evidence(self.a, "unit-a", authorized=False)
        self.repo.edit("unit-a", UNINFORMATIVE_FAILURES["the watchdog stopped the test attempt"])

        result = self.run_command(self.a)

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.splitlines(), [f"none {self.a}"])

    def test_without_a_logs_folder_every_worktree_is_searched(self):
        linked = self.repo.linked_worktree(self, self.a)
        make_unit_gate_pointer(linked, {"commit": self.a, "clean": True}, name="unit-linked")
        result_path = linked / ".build" / "gate-logs" / "unit-linked" / "gate.result.json"

        searched = self.run_command(self.a, logs=False)
        one_folder = self.run_command(self.a)  # --logs names this checkout's folder, which holds nothing

        self.assertEqual(searched.returncode, 0, searched.stderr)
        self.assertEqual(searched.stdout.splitlines(), [f"exact {self.a} {result_path}"])
        self.assertEqual(one_folder.returncode, 1)
        self.assertEqual(one_folder.stdout.splitlines(), [f"none {self.a}"])

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

    def setUp(self):
        super().setUp()
        self.listing = []  # the command lines ps shows, as live_run adds them

    def test_a_release_notes_commit_is_covered_when_the_contract_list_is_passed(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        source = {"commit": b, "clean": True}

        record = self.release.verify_unit_gate_precondition(self.repo.root, source, NEUTRAL)

        self.assertEqual((record["kind"], record["gatedCommit"], record["changedPaths"]),
                         ("inherited", self.a, [NOTES]))
        with self.assertRaisesRegex(self.release.ReleaseError, "no unit-tier gate evidence covers"):
            self.release.verify_unit_gate_precondition(self.repo.root, source)

    def test_a_failed_commit_on_the_way_is_refused_naming_the_commit_that_failed(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        self.repo.evidence(b, "unit-b", authorized=False)
        c = self.repo.commit("C: more release notes", {"docs/release-notes/2099.1.2.md": "More\n"})

        with self.assertRaises(self.release.UnitTierRed) as refused:
            self.release.verify_unit_gate_precondition(self.repo.root, {"commit": c, "clean": True}, NEUTRAL)

        message = str(refused.exception)
        self.assertIsInstance(refused.exception, self.release.ReleaseError)
        self.assertIn(f"the unit tier failed on {b[:12]}", message)
        self.assertNotIn(c[:12], message, "it is B that failed, not the candidate")
        self.assertIn(str(self.repo.result_path("unit-b")), message)
        # The same history without the failed run is covered through the release notes.
        self.repo.result_path("unit-b").unlink()
        self.assertEqual(self.release.verify_unit_gate_precondition(
            self.repo.root, {"commit": c, "clean": True}, NEUTRAL)["kind"], "inherited")

    def operations(self):
        """LocalReleaseOperations over the throwaway repository and the shipped contract."""
        operations = object.__new__(self.release.LocalReleaseOperations)
        operations.root = self.repo.root
        operations.contract = self.release.load_contract(CONTRACT)
        operations.runner = SimpleNamespace(environment={"PATH": "/usr/bin:/bin"}, run=mock.Mock())
        operations._process_command_lines = lambda: "\n".join(self.listing)
        return operations

    def test_package_inherits_through_the_contracts_neutral_paths_without_running_the_unit_tier(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        operations = self.operations()

        with mock.patch.object(self.release, "source_identity", return_value={"commit": b, "clean": True}):
            record = operations._ensure_unit_evidence({})

        self.assertEqual((record["kind"], record["gatedCommit"], record["changedPaths"]), ("inherited", self.a, [NOTES]))
        operations.runner.run.assert_not_called()

    def test_package_refuses_a_neutral_descendant_of_a_failed_commit_without_running_the_unit_tier(self):
        self.repo.evidence(self.a, "unit-a")
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        self.repo.evidence(b, "unit-b", authorized=False)
        c = self.repo.commit("C: more release notes", {"docs/release-notes/2099.1.2.md": "More\n"})
        operations = self.operations()

        with mock.patch.object(self.release, "source_identity", return_value={"commit": c, "clean": True}):
            with self.assertRaisesRegex(self.release.UnitTierRed, f"the unit tier failed on {b[:12]}"):
                operations._ensure_unit_evidence({})

        operations.runner.run.assert_not_called()

    def live_run(self, commit, root=None, tier="unit"):
        """A gate run still writing evidence for commit: no result yet, its
        folder names this live process the way full-suite-gate.sh names its
        own, and ps lists its gate_evidence.py command with its tier."""
        logs = (root or self.repo.root) / ".build" / "gate-logs"
        folder = logs / f"gate-20261008-105631-{commit[:9]}-{os.getpid()}"
        folder.mkdir(parents=True)
        (folder / "runner.log").write_text("Test Case started\n")
        self.listing.append(f"python3 scripts/release/gate_evidence.py swift --root {logs.parent.parent} "
                            f"--output {folder} --tier {tier} --quiet")
        return folder

    def finish(self, root, commit, folder, **options):
        """What the run in folder leaves when it ends."""
        return lambda: make_unit_gate_pointer(root, {"commit": commit, "clean": True}, name=folder.name, **options)

    def wait_on(self, operations, commit, finish, monotonic=None):
        """Run _ensure_unit_evidence for commit with a clock whose sleep calls
        finish, which leaves the result the run in progress would have left.
        The default clock moves ten minutes per reading, so a wait that never
        ends runs out its budget and fails instead of hanging the suite."""
        if monotonic is None:
            monotonic = itertools.count(0.0, 600.0).__next__
        slept = []

        def sleep(seconds):
            slept.append(seconds)
            finish()

        clock = SimpleNamespace(monotonic=monotonic, sleep=sleep, time=time.time)
        with mock.patch.object(self.release, "source_identity", return_value={"commit": commit, "clean": True}), \
                mock.patch.object(self.release, "time", clock), \
                contextlib.redirect_stdout(io.StringIO()) as printed:
            record = operations._ensure_unit_evidence({})
        return record, slept, printed.getvalue()

    def runs_own_tier(self, operations, commit):
        """Make the package's own unit-tier command leave passing evidence for commit."""
        ran = []
        operations.runner.run.side_effect = lambda command, **_: (
            ran.append(command),
            make_unit_gate_pointer(self.repo.root, {"commit": commit, "clean": True}, name="gate-own"),
            subprocess.CompletedProcess(command, 0))[-1]
        return ran

    def test_package_waits_for_a_unit_run_on_a_release_neutral_ancestor_and_inherits_it(self):
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        linked = self.repo.linked_worktree(self, self.a)
        folder = self.live_run(self.a, root=linked)
        operations = self.operations()

        record, slept, printed = self.wait_on(operations, b, self.finish(linked, self.a, folder))

        self.assertEqual((record["kind"], record["gatedCommit"], record["changedPaths"]), ("inherited", self.a, [NOTES]))
        self.assertEqual(slept, [30])
        self.assertIn(f"run on {self.a[:9]} decides this commit", printed)
        operations.runner.run.assert_not_called()

    def test_a_failed_unit_run_on_a_neutral_ancestor_refuses_the_package_without_a_second_run(self):
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        linked = self.repo.linked_worktree(self, self.a)
        folder = self.live_run(self.a, root=linked)
        operations = self.operations()

        with self.assertRaisesRegex(self.release.UnitTierRed, f"the unit tier failed on {self.a[:12]}"):
            self.wait_on(operations, b, self.finish(linked, self.a, folder, authorized=False))

        operations.runner.run.assert_not_called()

    def test_package_waits_out_a_run_in_this_checkout_whose_commit_moved_then_runs_its_own(self):
        # 2026.10.11: a unit-tier run on the parent was going in this checkout
        # when the release notes were committed on top. Its result can only say
        # "source changed during gate", so nothing inherits it. Package waits for
        # it to release the build folder, visibly, and then runs the tier once.
        # Before, its own run sat on the SwiftPM lock for 25 minutes.
        folder = self.live_run(self.a)
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        operations = self.operations()
        ran = self.runs_own_tier(operations, b)

        def moved():
            make_unit_gate_pointer(self.repo.root, {"commit": self.a, "clean": True}, authorized=False, name=folder.name)
            self.repo.edit(folder.name, UNINFORMATIVE_FAILURES["the checkout changed during the run"])

        record, slept, printed = self.wait_on(operations, b, moved)

        self.assertNotIn("decides this commit", printed, "a run whose checkout moved decides nothing")
        self.assertIn(f"run on {self.a[:9]} is using this checkout's build folder", printed)
        self.assertEqual((record["kind"], record["gatedCommit"], slept, len(ran)), ("exact", b, [30], 1))

    def test_only_a_unit_tier_run_on_a_checkout_still_at_its_commit_decides(self):
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        operations = self.operations()
        cases = (
            ("a unit run", "unit", False, self.a[:9]),
            ("a full-tier run, which is never unit evidence", "full", False, None),
            ("a unit run whose checkout moved on", "unit", True, None),
        )
        for label, tier, move, expected in cases:
            with self.subTest(label):
                self.listing.clear()
                linked = self.repo.linked_worktree(self, self.a)
                self.live_run(self.a, root=linked, tier=tier)
                if move:
                    subprocess.run(["git", "-C", str(linked), "checkout", "-q", "--detach", b], check=True,
                                   env=GIT_ENVIRONMENT)

                self.assertEqual(operations._deciding_unit_gate(b), expected)
                self.assertEqual(len(operations._related_live_gates(b)), 1, "the run itself is live and related")
                shutil.rmtree(linked / ".build")

    def test_a_full_tier_run_on_a_neutral_ancestor_elsewhere_does_not_delay_the_package(self):
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        self.live_run(self.a, root=self.repo.linked_worktree(self, self.a), tier="full")
        operations = self.operations()
        ran = self.runs_own_tier(operations, b)

        record, slept, _ = self.wait_on(operations, b, lambda: self.fail("must not wait"))

        self.assertEqual((record["kind"], slept, len(ran)), ("exact", [], 1))

    def test_a_run_on_an_ancestor_with_code_changes_since_does_not_decide_the_package(self):
        b = self.code(2)
        self.live_run(self.a, root=self.repo.linked_worktree(self, self.a))
        operations = self.operations()

        self.assertIsNone(operations._deciding_unit_gate(b), "its result could never cover b")
        self.assertEqual(operations._deciding_unit_gate(self.a), self.a[:9])

    def test_a_run_on_a_descendant_or_sibling_does_not_decide_the_package(self):
        b = self.notes(2)
        self.repo.git("checkout", "-q", "-b", "side", self.a)
        sibling = self.notes(3)
        self.repo.git("checkout", "-q", "main")
        self.live_run(b, root=self.repo.linked_worktree(self, b))
        self.live_run(sibling, root=self.repo.linked_worktree(self, sibling))
        operations = self.operations()

        self.assertEqual(operations._related_live_gates(self.a), [])
        self.assertIsNone(operations._deciding_unit_gate(self.a))

    def test_package_waits_for_another_run_using_this_checkouts_build_folder_then_runs_its_own(self):
        # SwiftPM builds one thing at a time per .build folder, so a second
        # unit-tier run there only waits on its lock.
        b = self.code(2)
        folder = self.live_run(self.a, tier="integration")
        operations = self.operations()
        ran = self.runs_own_tier(operations, b)

        record, slept, printed = self.wait_on(operations, b, self.finish(self.repo.root, self.a, folder))

        self.assertEqual((record["kind"], record["gatedCommit"]), ("exact", b))
        self.assertEqual(slept, [30], "it waited for the other run before starting its own")
        self.assertIn("build folder", printed)
        self.assertEqual(len(ran), 1)

    def test_a_run_on_unrelated_code_in_another_worktree_does_not_delay_the_package(self):
        b = self.code(2)
        self.live_run(self.a, root=self.repo.linked_worktree(self, self.a))
        operations = self.operations()
        ran = self.runs_own_tier(operations, b)

        record, slept, _ = self.wait_on(operations, b, lambda: self.fail("must not wait"))

        self.assertEqual((record["kind"], slept, len(ran)), ("exact", [], 1))

    def test_evidence_that_lands_after_the_first_look_is_reused_not_repeated(self):
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        operations = self.operations()

        def finished_meanwhile(_commit):
            make_unit_gate_pointer(self.repo.root, {"commit": self.a, "clean": True}, name="gate-late")
            return None

        operations._deciding_unit_gate = finished_meanwhile
        record, slept, _ = self.wait_on(operations, b, lambda: self.fail("must not wait"))

        self.assertEqual((record["kind"], record["gatedCommit"], slept), ("inherited", self.a, []))
        operations.runner.run.assert_not_called()

    def test_both_waits_share_one_budget(self):
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        linked = self.repo.linked_worktree(self, self.a)
        deciding = self.live_run(self.a, root=linked)
        self.live_run("f" * 40)  # another run in this checkout, on code outside this history
        operations = self.operations()
        readings = iter([0.0, 10.0, self.release.UNIT_GATE_WAIT_SECONDS + 1.0])

        def says_nothing():
            # The deciding run ends without a verdict, so the build-folder wait follows.
            make_unit_gate_pointer(linked, {"commit": self.a, "clean": True}, authorized=False, name=deciding.name)
            self.repo.edit_in(linked, deciding.name, UNINFORMATIVE_FAILURES["the watchdog stopped the test attempt"])

        with self.assertRaisesRegex(self.release.ReleaseError, "in this checkout has not finished after 60 minutes"):
            self.wait_on(operations, b, says_nothing, monotonic=lambda: next(readings))

        operations.runner.run.assert_not_called()

    def test_a_green_deciding_run_is_used_at_once_while_another_run_holds_this_checkout(self):
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        linked = self.repo.linked_worktree(self, self.a)
        deciding = self.live_run(self.a, root=linked)
        self.live_run("f" * 40)  # still going when the deciding run ends
        operations = self.operations()

        record, slept, printed = self.wait_on(operations, b, self.finish(linked, self.a, deciding))

        self.assertEqual((record["kind"], record["gatedCommit"], slept), ("inherited", self.a, [30]))
        self.assertNotIn("build folder", printed, "evidence already covers b, so nothing waits for the other run")
        operations.runner.run.assert_not_called()

    def test_a_unit_run_in_a_worktree_whose_path_has_a_space_still_decides(self):
        b = self.repo.commit("B: release notes", {NOTES: "Notes\n"})
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        spaced = Path(temporary.name).resolve() / "Application Support" / "lane"
        self.repo.git("worktree", "add", "-q", "--detach", str(spaced), self.a)
        self.live_run(self.a, root=spaced)
        operations = self.operations()

        self.assertEqual(operations._deciding_unit_gate(b), self.a[:9])

    def test_waiting_on_another_run_in_this_checkout_is_bounded(self):
        b = self.code(2)
        self.live_run(self.a)
        operations = self.operations()
        readings = iter([0.0, 10.0 ** 9])

        with self.assertRaisesRegex(self.release.ReleaseError, "has not finished after 60 minutes"):
            self.wait_on(operations, b, lambda: None, monotonic=lambda: next(readings))

        operations.runner.run.assert_not_called()

    def test_a_code_commit_is_refused_even_with_the_contract_list(self):
        self.repo.evidence(self.a, "unit-a")
        code = self.repo.commit("B: code", {"Sources/x.swift": "let x = 9\n"})

        with self.assertRaisesRegex(self.release.ReleaseError, "no unit-tier gate evidence covers"):
            self.release.verify_unit_gate_precondition(self.repo.root, {"commit": code, "clean": True}, NEUTRAL)


if __name__ == "__main__":
    unittest.main()
