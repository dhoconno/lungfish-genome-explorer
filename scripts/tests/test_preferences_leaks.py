"""Tests for scripts/testing/preferences-leaks.py and its wiring in scripts/full-suite-gate.sh.

Phase 2.9 lane Q10, decision H1. Every test builds a throwaway Preferences folder, Tests tree and
allowed list in a temporary directory, so nothing reads or writes the real ~/Library/Preferences.
Four tests read the real checkout: they pin the shipped allowed list (each row names a file that
still builds its prefix, the list only shrinks, the eleven classes moved onto TestDefaultsSuite
stay off it) and the gate's call of the script.
"""

import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/testing/preferences-leaks.py"
ALLOWED = ROOT / "scripts/testing/preferences-leaks-allowed.txt"
GATE = ROOT / "scripts/full-suite-gate.sh"

# The allowed list may only shrink. Lower this number with it, never raise it.
SEEDED_ROWS = 73

# The eleven classes the owner named, moved onto TestDefaultsSuite by the first milestone of Q10.
ELEVEN = {
    "ClassifierCLIRouteRowTests": "Tests/LungfishAppTests/ClassifierCLIRouteRowTests.swift",
    "ClassifierLaunchRouteTests": "Tests/LungfishAppTests/ClassifierLaunchRouteTests.swift",
    "DemoProjectsAccessibilityTests": "Tests/LungfishAppTests/DemoProjectsAccessibilityTests.swift",
    "DemoProjectsViewModelTests": "Tests/LungfishAppTests/DemoProjectsViewModelTests.swift",
    "FASTQOperationDialogRoutingTests": "Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift",
    "HumanScrubberDatabaseTests": "Tests/LungfishWorkflowTests/HumanScrubberDatabaseTests.swift",
    "SiblingRootDatabaseCloneTests": "Tests/LungfishWorkflowTests/SiblingRootDatabaseCloneTests.swift",
    "TwelveSInputWordingTests": "Tests/LungfishAppTests/TwelveSInputWordingTests.swift",
    "WorkflowLibraryTests": "Tests/LungfishAppWorkflowTests/WorkflowLibraryTests.swift",
    "WorkflowOperationDialogStateTests": "Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift",
    "WorkflowRunAgainStateTests": "Tests/LungfishAppWorkflowTests/WorkflowRunAgainStateTests.swift",
}


def load_script():
    spec = importlib.util.spec_from_file_location("preferences_leaks", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


leaks = load_script()


def uuid(number: int) -> str:
    return f"{number:08X}-0000-4000-8000-{number:012X}"


class WorkspaceCase(unittest.TestCase):
    """A Preferences folder, a Tests tree and an allowed list in a temporary directory."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lungfish-preferences-leaks-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.preferences = self.tmp / "Preferences"
        self.preferences.mkdir()
        self.tests = self.tmp / "Tests"
        self.tests.mkdir()
        self.allowed = self.tmp / "allowed.txt"
        self.allowed.write_text("")
        self.snapshot = self.tmp / "before.json"
        self.report = self.tmp / "report.txt"
        self.serial = 0

    def swift(self, relative, text):
        path = self.tests / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return f"Tests/{relative}"

    def plist(self, prefix, separator="-", suffix=""):
        self.serial += 1
        name = f"{prefix}{separator if prefix else ''}{uuid(self.serial)}{suffix}.plist"
        (self.preferences / name).write_text("{}")
        return name

    def allow(self, *rows):
        self.allowed.write_text("".join(f"{prefix} {file}\n" for prefix, file in rows))

    def args(self, *more):
        return [*more, "--preferences-dir", str(self.preferences), "--tests-root", str(self.tests),
                "--allowed", str(self.allowed)]

    def run_script(self, *argv, sleep=lambda seconds: None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = leaks.main(list(argv), sleep=sleep)
        return status, out.getvalue(), err.getvalue()

    def take_snapshot(self):
        status, out, err = self.run_script("snapshot", *self.args("--output", str(self.snapshot)))
        self.assertEqual(status, 0, out + err)

    def check(self, sleep=lambda seconds: None):
        return self.run_script("check", *self.args("--before", str(self.snapshot), "--report", str(self.report)),
                               sleep=sleep)


class PlistNameTests(unittest.TestCase):
    def test_the_prefix_is_what_comes_before_the_separator_and_the_uuid(self):
        cases = {
            f"ClassifierLaunchRouteTests-{uuid(1)}.plist": "ClassifierLaunchRouteTests",
            f"LungfishTypographyTests.{uuid(2)}.plist": "LungfishTypographyTests",
            f"lungfish-test-{uuid(3)}.plist": "lungfish-test",
            f"WorkflowFeatureAvailability-12S-{uuid(4)}.plist": "WorkflowFeatureAvailability-12S",
            f"org.lungfish.tests.AppSettings.nested-{uuid(5)}.plist": "org.lungfish.tests.AppSettings.nested",
            f"com.openai.chat.RemoteFeatureFlags-{uuid(6).lower()}.plist": "com.openai.chat.RemoteFeatureFlags",
            f"{uuid(7)}.plist": "",
        }
        for name, prefix in cases.items():
            with self.subTest(name=name):
                self.assertEqual(leaks.plist_prefix(name), prefix)

    def test_a_suffix_after_the_uuid_keeps_the_prefix(self):
        self.assertEqual(leaks.plist_prefix(f"ClassifierLaunchRouteTests-{uuid(1)}-unset.plist"),
                         "ClassifierLaunchRouteTests")

    def test_a_file_that_is_not_a_uuid_named_plist_has_no_prefix(self):
        for name in ("LungfishFixProbe-D.plist", "org.example.storage-tests.plist", f"Foo-{uuid(1)}",
                     f"Foo-{uuid(1)}.plist.tmp", "Foo-1234.plist", ".GlobalPreferences.plist"):
            with self.subTest(name=name):
                self.assertIsNone(leaks.plist_prefix(name))


class ScanTestsTests(WorkspaceCase):
    def prefixes(self):
        built = leaks.scan_tests(self.tests)
        return built.by_hand, built.by_helper

    def test_a_name_built_by_hand_is_found_with_its_file(self):
        file = self.swift("A/FooTests.swift", 'let a = "FooTests-\\(UUID().uuidString)"\n'
                                              'let b = "dotted.\\(UUID().uuidString)"\n'
                                              'let c = "fn-\\(UUID())"\n'
                                              'let d = "joined." + UUID().uuidString\n')
        by_hand, by_helper = self.prefixes()
        self.assertEqual(by_hand, {"FooTests": {file}, "dotted": {file}, "fn": {file}, "joined": {file}})
        self.assertEqual(by_helper, {})

    def test_a_suite_named_by_a_bare_uuid_has_the_empty_prefix(self):
        file = self.swift("B/BareTests.swift", "let d = UserDefaults(suiteName: UUID().uuidString)!\n")
        by_hand, _ = self.prefixes()
        self.assertEqual(by_hand, {"": {file}})

    def test_a_prefix_passed_to_the_helper_is_found(self):
        file = self.swift("C/HelperTests.swift",
                          'let a = TestDefaultsSuite(prefix: "HelperTests")\n'
                          'let b = makeTestDefaultsSuite(prefix: "HelperTests-unset").defaults\n'
                          'let c = TestTempDirectory.make(prefix: "not-a-suite")\n')
        by_hand, by_helper = self.prefixes()
        self.assertEqual(by_hand, {})
        self.assertEqual(by_helper, {"HelperTests": {file}, "HelperTests-unset": {file}})

    def test_text_with_another_interpolation_before_the_uuid_is_not_a_name(self):
        self.swift("D/OddTests.swift", 'let a = "\\(base)-\\(UUID().uuidString)"\nlet b = "plain"\n')
        by_hand, by_helper = self.prefixes()
        self.assertEqual((by_hand, by_helper), ({}, {}))

    def test_fixture_and_build_folders_are_not_read(self):
        self.swift("Fixtures/FooTests.swift", 'let a = "Hidden-\\(UUID().uuidString)"\n')
        self.swift("E/ReadTests.swift", 'let a = "Seen-\\(UUID().uuidString)"\n')
        by_hand, _ = self.prefixes()
        self.assertEqual(set(by_hand), {"Seen"})

    def test_the_files_that_call_user_defaults_suite_name_are_found_except_the_helper(self):
        caller = self.swift("F/SuiteTests.swift", 'let d = UserDefaults(suiteName: name)\n')
        self.swift("F/PlainTests.swift", "let d = UserDefaults.standard\n")
        self.swift("Support/LungfishTestSupport/TestDefaultsSuite.swift", 'let d = UserDefaults(suiteName: name)\n')
        self.assertEqual(leaks.scan_tests(self.tests).suite_files, {caller})


class AllowedListTests(WorkspaceCase):
    def test_a_row_is_a_prefix_and_a_file_and_comments_are_ignored(self):
        self.allowed.write_text("# header\n\nFooTests  Tests/A/FooTests.swift  # why\n(none) Tests/B/Bare.swift\n")
        rows = leaks.load_allowed(self.allowed)
        self.assertEqual([(r.prefix, r.file) for r in rows], [("FooTests", "Tests/A/FooTests.swift"), ("", "Tests/B/Bare.swift")])

    def test_a_malformed_row_is_refused(self):
        self.allowed.write_text("FooTests\n")
        with self.assertRaises(leaks.AllowedListError):
            leaks.load_allowed(self.allowed)

    def test_lint_flags_a_row_whose_file_moved_onto_the_helper(self):
        self.swift("A/FooTests.swift", 'let a = TestDefaultsSuite(prefix: "FooTests")\n')
        rows = [leaks.Row("FooTests", "Tests/A/FooTests.swift", 3)]
        problems = leaks.lint(rows, leaks.scan_tests(self.tests), self.tmp, "allowed.txt")
        self.assertEqual(len(problems), 1)
        self.assertIn("allowed.txt:3", problems[0])
        self.assertIn("no longer builds 'FooTests-<UUID>' by hand, delete the row", problems[0])

    def test_lint_flags_a_missing_file_and_a_repeated_row(self):
        self.swift("A/FooTests.swift", 'let a = "FooTests-\\(UUID().uuidString)"\n')
        rows = [leaks.Row("FooTests", "Tests/A/FooTests.swift", 1), leaks.Row("FooTests", "Tests/A/FooTests.swift", 2),
                leaks.Row("Gone", "Tests/A/Gone.swift", 3)]
        problems = leaks.lint(rows, leaks.scan_tests(self.tests), self.tmp)
        self.assertEqual(len(problems), 2)
        self.assertIn("listed twice", problems[0])
        self.assertIn("does not exist, delete the row", problems[1])

    def test_lint_passes_a_row_whose_file_still_builds_the_prefix(self):
        self.swift("A/FooTests.swift", 'let a = "FooTests-\\(UUID().uuidString)"\n')
        rows = [leaks.Row("FooTests", "Tests/A/FooTests.swift", 1)]
        self.assertEqual(leaks.lint(rows, leaks.scan_tests(self.tests), self.tmp), [])

    def test_lint_flags_a_new_test_that_builds_a_suite_by_hand_and_has_no_row(self):
        file = self.swift("A/NewTests.swift", 'let n = "NewTests-\\(UUID().uuidString)"\nlet d = UserDefaults(suiteName: n)\n')
        problems = leaks.lint([], leaks.scan_tests(self.tests), self.tmp, "allowed.txt")
        self.assertEqual(problems, [f"{file} calls UserDefaults(suiteName:) and is not on the allowed.txt, use TestDefaultsSuite instead"])

    def test_the_snapshot_command_refuses_to_start_a_tier_with_such_a_test(self):
        self.swift("A/NewTests.swift", 'let d = UserDefaults(suiteName: "NewTests-\\(UUID().uuidString)")\n')
        status, out, err = self.run_script("snapshot", *self.args("--output", str(self.snapshot)))
        self.assertEqual(status, 3, out + err)
        self.assertIn("use TestDefaultsSuite instead", err)
        self.assertFalse(self.snapshot.exists())

    def test_the_lint_command_exits_3_on_a_stale_row(self):
        self.allow(("FooTests", "Tests/A/FooTests.swift"))
        status, out, err = self.run_script("lint", *self.args())
        self.assertEqual(status, 3, out + err)
        self.assertIn("does not exist", err)


class SnapshotTests(WorkspaceCase):
    def test_a_snapshot_lists_only_uuid_named_plists(self):
        keep = self.plist("FooTests")
        (self.preferences / "com.apple.finder.plist").write_text("{}")
        (self.preferences / "LungfishFixProbe-D.plist").write_text("{}")
        (self.preferences / ".DS_Store").write_text("")
        self.take_snapshot()
        data = json.loads(self.snapshot.read_text())
        self.assertEqual(data["names"], [keep])
        self.assertEqual(data["directory"], str(self.preferences))

    def test_a_stale_allowed_list_stops_the_snapshot_before_the_tier(self):
        self.allow(("FooTests", "Tests/A/FooTests.swift"))
        status, out, err = self.run_script("snapshot", *self.args("--output", str(self.snapshot), "--report", str(self.report)))
        self.assertEqual(status, 3)
        self.assertFalse(self.snapshot.exists())
        self.assertIn("the allowed list is stale", self.report.read_text())

    def test_a_missing_preferences_folder_counts_as_empty(self):
        shutil.rmtree(self.preferences)
        self.take_snapshot()
        self.assertEqual(json.loads(self.snapshot.read_text())["names"], [])


class CheckTests(WorkspaceCase):
    def setUp(self):
        super().setUp()
        self.foo = self.swift("A/FooTests.swift", 'let a = "FooTests-\\(UUID().uuidString)"\n')
        self.plist("Preexisting")

    def test_a_tier_that_writes_nothing_passes(self):
        self.take_snapshot()
        status, out, err = self.check()
        self.assertEqual(status, 0, out + err)
        self.assertIn("PASS - 0 new UUID-named plists", out)
        self.assertFalse(self.report.exists())

    def test_a_new_plist_whose_prefix_a_test_builds_fails_unless_the_list_allows_it(self):
        self.take_snapshot()
        name = self.plist("FooTests")
        status, out, err = self.check()
        self.assertEqual(status, 1, out + err)
        self.assertIn("FAIL", err)
        self.assertIn(name, err)
        self.assertIn(self.foo, err)
        self.assertIn("TestDefaultsSuite", err)
        self.assertIn("FAIL", self.report.read_text())

    def test_a_new_plist_on_the_allowed_list_passes_and_is_counted(self):
        self.allow(("FooTests", self.foo))
        self.take_snapshot()
        self.plist("FooTests")
        self.plist("FooTests", separator=".")
        status, out, err = self.check()
        self.assertEqual(status, 0, out + err)
        self.assertIn("2 new UUID-named plists", out)
        self.assertIn("2 on the allowed list", out)

    def test_a_plist_that_was_already_there_is_not_new(self):
        self.plist("FooTests")
        self.take_snapshot()
        status, out, err = self.check()
        self.assertEqual(status, 0, out + err)

    def test_another_apps_plist_is_counted_and_never_fails(self):
        self.take_snapshot()
        self.plist("com.openai.chat.RemoteFeatureFlags")
        status, out, err = self.check()
        self.assertEqual(status, 0, out + err)
        self.assertIn("1 from other apps", out)

    def test_a_prefix_only_the_helper_builds_still_counts(self):
        self.swift("B/HelperTests.swift", 'let s = makeTestDefaultsSuite(prefix: "HelperTests")\n')
        self.take_snapshot()
        name = self.plist("HelperTests")
        status, out, err = self.check()
        self.assertEqual(status, 1, out + err)
        self.assertIn(name, err)

    def test_a_suffix_after_the_uuid_still_counts_against_the_prefix(self):
        self.take_snapshot()
        name = self.plist("FooTests", suffix="-unset")
        status, out, err = self.check()
        self.assertEqual(status, 1, out + err)
        self.assertIn(name, err)

    def test_a_plist_that_appears_during_the_settle_is_caught_by_the_second_scan(self):
        self.take_snapshot()
        seen = []

        def late_write(seconds):
            seen.append(seconds)
            self.plist("FooTests")

        status, out, err = self.check(sleep=late_write)
        self.assertEqual(status, 1, out + err)
        self.assertEqual(len(seen), 1)
        self.assertIn("appeared or went away during the settle", err)

    def test_a_plist_that_goes_away_during_the_settle_is_not_a_leak(self):
        self.take_snapshot()
        name = self.plist("FooTests")
        status, out, err = self.check(sleep=lambda seconds: (self.preferences / name).unlink())
        self.assertEqual(status, 0, out + err)

    def test_the_default_settle_waits_three_seconds(self):
        self.take_snapshot()
        waited = []
        with mock_environment_without("LUNGFISH_PREFERENCES_SETTLE_SECONDS"):
            status, out, err = self.run_script(
                "check", *self.args("--before", str(self.snapshot)), sleep=waited.append)
        self.assertEqual((status, waited), (0, [3.0]), out + err)

    def test_a_missing_snapshot_is_an_input_error(self):
        status, out, err = self.check()
        self.assertEqual(status, 4, out + err)
        self.assertIn("cannot read the snapshot", err)

    def test_a_snapshot_of_another_folder_is_an_input_error(self):
        self.take_snapshot()
        other = self.tmp / "Other"
        other.mkdir()
        status, out, err = self.run_script(
            "check", "--before", str(self.snapshot), "--preferences-dir", str(other),
            "--tests-root", str(self.tests), "--allowed", str(self.allowed))
        self.assertEqual(status, 4, out + err)
        self.assertIn("not " + str(other), err)

    def test_the_prefixes_command_lists_each_prefix_with_its_file_and_how_it_is_built(self):
        self.swift("B/HelperTests.swift", 'let s = TestDefaultsSuite(prefix: "HelperTests")\n')
        status, out, err = self.run_script("prefixes", *self.args())
        self.assertEqual(status, 0, err)
        self.assertEqual(out.splitlines(), [f"FooTests\t{self.foo}\tby-hand", "HelperTests\tTests/B/HelperTests.swift\thelper"])

    def test_the_script_runs_as_a_program_with_the_folder_from_the_environment(self):
        env = {**os.environ, "LUNGFISH_PREFERENCES_DIR": str(self.preferences), "LUNGFISH_PREFERENCES_SETTLE_SECONDS": "0"}
        common = ["--tests-root", str(self.tests), "--allowed", str(self.allowed)]
        first = subprocess.run([sys.executable, str(SCRIPT), "snapshot", "--output", str(self.snapshot), *common],
                               env=env, capture_output=True, text=True)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.plist("FooTests")
        second = subprocess.run([sys.executable, str(SCRIPT), "check", "--before", str(self.snapshot), *common],
                                env=env, capture_output=True, text=True)
        self.assertEqual(second.returncode, 1, second.stdout + second.stderr)
        self.assertIn("FAIL", second.stderr)


@contextlib.contextmanager
def mock_environment_without(name):
    saved = os.environ.pop(name, None)
    try:
        yield
    finally:
        if saved is not None:
            os.environ[name] = saved


class ShippedAllowedListTests(unittest.TestCase):
    def test_every_row_names_a_file_that_still_builds_its_prefix_by_hand(self):
        built = leaks.scan_tests(ROOT / "Tests")
        self.assertEqual(leaks.lint(leaks.load_allowed(ALLOWED), built, ROOT, ALLOWED.name), [])

    def test_the_list_only_shrinks(self):
        rows = leaks.load_allowed(ALLOWED)
        self.assertLessEqual(
            len(rows), SEEDED_ROWS,
            "a row was added to preferences-leaks-allowed.txt: give the test TestDefaultsSuite instead")

    def test_the_eleven_classes_build_no_suite_by_hand_and_are_not_on_the_list(self):
        listed = {row.file for row in leaks.load_allowed(ALLOWED)}
        for name, relative in ELEVEN.items():
            with self.subTest(name=name):
                text = (ROOT / relative).read_text(encoding="utf-8")
                self.assertNotIn("UserDefaults(suiteName:", text)
                self.assertIn(f'(prefix: "{name}"', text)
                self.assertNotIn(relative, listed)

    def test_the_helper_and_its_test_exist(self):
        for relative in ("Tests/Support/LungfishTestSupport/TestDefaultsSuite.swift",
                         "Tests/LungfishCoreTests/TestDefaultsSuiteTests.swift"):
            self.assertTrue((ROOT / relative).is_file(), relative)


class GateWiringTests(unittest.TestCase):
    EVIDENCE_STUB = (
        "import os, pathlib, sys\n"
        "output = pathlib.Path(sys.argv[sys.argv.index('--output') + 1])\n"
        "output.mkdir(parents=True)\n"
        "(output / 'gate.result.json').write_text('{}\\n')\n"
        "if os.environ.get('STUB_MARKER'):\n"
        "    pathlib.Path(os.environ['STUB_MARKER']).write_text('ran')\n"
        "for name in filter(None, os.environ.get('STUB_WRITES', '').split(',')):\n"
        "    (pathlib.Path(os.environ['LUNGFISH_PREFERENCES_DIR']) / name).write_text('{}')\n"
        "sys.exit(int(os.environ.get('STUB_EXIT', '0')))\n"
    )

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lungfish-preferences-gate-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.project = self.tmp / "project"
        (self.project / "scripts/release").mkdir(parents=True)
        (self.project / "scripts/testing").mkdir(parents=True)
        shutil.copy2(GATE, self.project / "scripts/full-suite-gate.sh")
        shutil.copy2(SCRIPT, self.project / "scripts/testing/preferences-leaks.py")
        (self.project / "scripts/release/gate_evidence.py").write_text(self.EVIDENCE_STUB)
        suite = self.project / "Tests/LungfishAppTests/ExampleTests.swift"
        suite.parent.mkdir(parents=True)
        suite.write_text('let suite = "ExampleTests-\\(UUID().uuidString)"\n')
        self.allow()
        self.preferences = self.tmp / "Preferences"
        self.preferences.mkdir()
        self.marker = self.tmp / "tier-ran"

    def allow(self, *rows):
        (self.project / "scripts/testing/preferences-leaks-allowed.txt").write_text(
            "".join(f"{prefix} {file}\n" for prefix, file in rows))

    def run_gate(self, *options, writes=(), stub_exit=0):
        env = {**os.environ, "LUNGFISH_RELEASE_PYTHON": sys.executable,
               "LUNGFISH_PREFERENCES_DIR": str(self.preferences), "LUNGFISH_PREFERENCES_SETTLE_SECONDS": "0",
               "STUB_WRITES": ",".join(writes), "STUB_EXIT": str(stub_exit), "STUB_MARKER": str(self.marker)}
        return subprocess.run(["/bin/bash", str(self.project / "scripts/full-suite-gate.sh"), "--tier", "smoke", *options],
                              cwd=self.tmp, env=env, capture_output=True, text=True, timeout=120)

    def leftovers(self):
        return sorted(p.name for p in (self.project / ".build/gate-logs").glob("*.preferences*"))

    def test_the_gate_calls_the_script_before_and_after_the_tier(self):
        text = GATE.read_text(encoding="utf-8")
        self.assertTrue(SCRIPT.is_file())
        snapshot = text.index('"$PREFERENCES_LEAKS" snapshot')
        tier = text.index('"${command[@]}"')
        check = text.index('"$PREFERENCES_LEAKS" check')
        self.assertLess(snapshot, tier)
        self.assertLess(tier, check)

    def test_a_clean_tier_passes_and_leaves_no_files_beside_the_evidence(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("preferences-leaks: PASS", result.stdout)
        self.assertTrue(self.marker.exists())
        self.assertEqual(self.leftovers(), [])

    def test_a_tier_that_leaves_a_plist_a_test_builds_fails_the_gate(self):
        name = f"ExampleTests-{uuid(1)}.plist"
        result = self.run_gate(writes=[name])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("preferences-leaks: FAIL", result.stderr)
        self.assertIn(name, result.stderr)
        # The snapshot is gone and the failed verdict stays beside the evidence.
        (kept,) = self.leftovers()
        self.assertTrue(kept.endswith(".preferences.txt"), kept)

    def test_a_plist_on_the_allowed_list_does_not_fail_the_gate(self):
        self.allow(("ExampleTests", "Tests/LungfishAppTests/ExampleTests.swift"))
        result = self.run_gate(writes=[f"ExampleTests-{uuid(1)}.plist"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("1 on the allowed list", result.stdout)

    def test_another_apps_plist_does_not_fail_the_gate(self):
        result = self.run_gate(writes=[f"com.example.other-{uuid(1)}.plist"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_failing_tier_keeps_its_own_exit_status(self):
        result = self.run_gate(writes=[f"ExampleTests-{uuid(1)}.plist"], stub_exit=7)
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertIn("preferences-leaks: FAIL", result.stderr)

    def test_a_stale_allowed_list_stops_the_gate_before_the_tier_runs(self):
        self.allow(("Gone", "Tests/LungfishAppTests/Gone.swift"))
        result = self.run_gate()
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertFalse(self.marker.exists(), "the tier ran")
        self.assertIn("the allowed list is stale", result.stderr)

    def test_the_quiet_gate_repeats_a_failed_check_after_its_fail_line(self):
        result = self.run_gate("--quiet", writes=[f"ExampleTests-{uuid(1)}.plist"])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("GATE FAIL", result.stdout)
        self.assertIn("preferences-leaks: FAIL", result.stdout)

    def test_a_project_without_the_script_runs_the_tier_without_the_check(self):
        (self.project / "scripts/testing/preferences-leaks.py").unlink()
        result = self.run_gate(writes=[f"ExampleTests-{uuid(1)}.plist"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
