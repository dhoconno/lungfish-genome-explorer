"""Tests for scripts/ratchets/cli-parity-gaps.sh (docs/contracts/CLI-EQUIVALENCE.md).

Every test builds a small repository tree in tmp_path, copies the script into
it, and runs it there, so nothing touches the real repository.
"""
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "ratchets" / "cli-parity-gaps.sh"

PARSING_SITE = '''
extension Thing {
    /// Records the import command.
    static func beginImportOperation(reporter: any OperationReporting) -> OperationStartResult {
        reporter.begin(
            title: "Import (one)",
            detail: "Importing \\(name)...",
            operationType: .ingestion,
            cliCommand: OperationCenter.buildCLICommand(subcommand: "import", args: ["fasta"])
        )
    }
}
'''

GAP_SITE = '''
extension Thing {
    /// Records no command.
    ///
    /// cli-parity-gap: thing-merge. No command merges things.
    static func beginMergeOperation(reporter: any OperationReporting) -> OperationStartResult {
        reporter.begin(
            title: "Merge",
            detail: "Merging...",
            operationType: .bundleBuild,
            cliCommand: nil
        )
    }
}
'''

NIL_SITE_NO_MARKER = '''
extension Thing {
    static func beginCopyOperation(reporter: any OperationReporting) -> OperationStartResult {
        reporter.begin(title: "Copy", detail: "", operationType: .ingestion, cliCommand: nil)
    }
}
'''

EXEMPT_SITE = '''
extension Thing {
    /// cli-parity-exempt: not-an-operation. A fixture row.
    static func beginSeedOperation(reporter: any OperationReporting) -> OperationStartResult {
        reporter.begin(title: "Seed", detail: "", operationType: .classification, cliCommand: nil)
    }
}
'''

INLINE_SITE = '''
final class Delegate {
    private func attachTrack(url: URL) async {
        let routeContext = currentRoute()
        let startResult = OperationCenter.shared.begin(
            title: "Annotation Import",
            detail: "Importing \\(url.lastPathComponent)...",
            operationType: .bundleBuild,
            cliCommand: nil, // cli-parity-gap: track-attach. No command attaches a track.
            routeContext: routeContext
        )
        _ = startResult
    }
}
'''

FORWARDER = '''
public extension OperationReporting {
    func begin(title: String, detail: String, operationType: OperationType, cliCommand: String?) -> OperationStartResult {
        begin(title: title, detail: detail, operationType: operationType, cliCommand: cliCommand, routeContext: nil)
    }
}
'''

PARSE_TEST = '''
final class ImportTests: XCTestCase {
    func testImport() throws {
        Thing.beginImportOperation(reporter: reporter)
        _ = try RecordedCLICommand.parse(item.cliCommand)
    }
}
'''

GAP_TEST = '''
final class MergeTests: XCTestCase {
    func testMerge() {
        Thing.beginMergeOperation(reporter: reporter)
        assertCLIParityGap(
            item.cliCommand,
            id: "thing-merge"
        )
    }
}
'''

SEED_TEST = '''
final class SeedTests: XCTestCase {
    func testSeed() {
        Thing.beginSeedOperation(reporter: reporter)
        XCTAssertThrowsError(try RecordedCLICommand.parseScript(item.cliCommand))
    }
}
'''


def make_repo(tmp_path, sources, tests=None, baseline=None, pending=None, untested=None):
    dest = tmp_path / "scripts" / "ratchets"
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copy(SCRIPT, dest / SCRIPT.name)
    for rel, text in sources.items():
        path = tmp_path / "Sources" / "LungfishApp" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    for rel, text in (tests or {}).items():
        path = tmp_path / "Tests" / "LungfishAppTests" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    if baseline is not None:
        (dest / "cli-parity-gaps.baseline").write_text(f"{baseline}\n")
    if pending is not None:
        (dest / "cli-parity-gaps.pending").write_text(pending)
    if untested is not None:
        (dest / "cli-parity-gaps.untested").write_text(untested)
    return dest / SCRIPT.name


def run(script, *args):
    return subprocess.run([sys.executable, str(script), *args], capture_output=True, text=True)


def test_parsing_site_and_pinned_gap_pass_at_the_baseline(tmp_path):
    script = make_repo(
        tmp_path,
        {"Import.swift": PARSING_SITE, "Merge.swift": GAP_SITE},
        {"ImportTests.swift": PARSE_TEST, "MergeTests.swift": GAP_TEST},
        baseline=1,
    )
    result = run(script)
    assert result.returncode == 0, result.stderr
    assert "1 gaps, at the baseline" in result.stdout


def test_value_over_the_baseline_fails(tmp_path):
    script = make_repo(
        tmp_path,
        {"Merge.swift": GAP_SITE},
        {"MergeTests.swift": GAP_TEST},
        baseline=0,
    )
    result = run(script)
    assert result.returncode == 1
    assert "up from the baseline of 0" in result.stderr


def test_missing_baseline_fails(tmp_path):
    script = make_repo(tmp_path, {"Import.swift": PARSING_SITE}, {"ImportTests.swift": PARSE_TEST})
    assert run(script).returncode == 1


def test_marker_without_a_pin_fails(tmp_path):
    script = make_repo(tmp_path, {"Merge.swift": GAP_SITE}, {"MergeTests.swift": SEED_TEST.replace("Seed", "Merge")}, baseline=1)
    result = run(script)
    assert result.returncode == 1
    assert "gap thing-merge" in result.stderr
    assert "no assertCLIParityGap" in result.stderr


def test_pin_without_a_marker_fails(tmp_path):
    script = make_repo(
        tmp_path,
        {"Import.swift": PARSING_SITE},
        {"ImportTests.swift": PARSE_TEST, "MergeTests.swift": GAP_TEST},
        baseline=0,
    )
    result = run(script)
    assert result.returncode == 1
    assert "test pins gap thing-merge" in result.stderr


def test_nil_command_without_a_marker_fails(tmp_path):
    script = make_repo(
        tmp_path,
        {"Copy.swift": NIL_SITE_NO_MARKER},
        {"CopyTests.swift": PARSE_TEST.replace("beginImportOperation", "beginCopyOperation")},
        baseline=0,
    )
    result = run(script)
    assert result.returncode == 1
    assert "records cliCommand: nil with no" in result.stderr


def test_exempt_nil_site_passes_and_is_not_counted(tmp_path):
    script = make_repo(tmp_path, {"Seed.swift": EXEMPT_SITE}, {"SeedTests.swift": SEED_TEST}, baseline=0)
    result = run(script)
    assert result.returncode == 0, result.stderr
    printed = run(script, "--print").stdout
    assert "beginSeedOperation exempt not-an-operation" in printed
    assert "TOTAL 0" in printed


def test_inline_marker_in_the_call_counts_for_its_site(tmp_path):
    script = make_repo(
        tmp_path,
        {"Delegate.swift": INLINE_SITE},
        {"PinTests.swift": 'func testPin() { assertCLIParityGap(nil, id: "track-attach") }\n'},
        baseline=1,
        untested="Sources/LungfishApp/Delegate.swift:attachTrack\n",
    )
    result = run(script)
    assert result.returncode == 0, result.stderr


def test_untested_site_fails_unless_listed(tmp_path):
    files = {"Import.swift": PARSING_SITE}
    script = make_repo(tmp_path, files, {"Other.swift": "// nothing\n"}, baseline=0)
    result = run(script)
    assert result.returncode == 1
    assert "Sources/LungfishApp/Import.swift:beginImportOperation holds a begin site" in result.stderr
    (tmp_path / "scripts/ratchets/cli-parity-gaps.untested").write_text(
        "Sources/LungfishApp/Import.swift:beginImportOperation\n"
    )
    assert run(script).returncode == 0


def test_a_test_that_names_the_function_but_parses_nothing_does_not_count(tmp_path):
    script = make_repo(
        tmp_path,
        {"Import.swift": PARSING_SITE},
        {"ImportTests.swift": "func testX() { Thing.beginImportOperation(reporter: r) }\n"},
        baseline=0,
    )
    assert run(script).returncode == 1


def test_pending_gap_counts_and_needs_no_pin(tmp_path):
    script = make_repo(
        tmp_path,
        {"Import.swift": PARSING_SITE},
        {"ImportTests.swift": PARSE_TEST},
        baseline=1,
        pending="# comment\nimport-batch Sources/LungfishApp/Import.swift:beginImportOperation L9\n",
    )
    result = run(script)
    assert result.returncode == 0, result.stderr
    printed = run(script, "--print").stdout
    assert "beginImportOperation pending import-batch" in printed
    assert "TOTAL 1" in printed


def test_pending_gap_over_the_baseline_fails(tmp_path):
    script = make_repo(
        tmp_path,
        {"Import.swift": PARSING_SITE},
        {"ImportTests.swift": PARSE_TEST},
        baseline=0,
        pending="import-batch Sources/LungfishApp/Import.swift:beginImportOperation L9\n",
    )
    assert run(script).returncode == 1


def test_gap_with_both_a_marker_and_a_pending_line_fails(tmp_path):
    script = make_repo(
        tmp_path,
        {"Merge.swift": GAP_SITE},
        {"MergeTests.swift": GAP_TEST},
        baseline=1,
        pending="thing-merge Sources/LungfishApp/Merge.swift:beginMergeOperation L2\n",
    )
    result = run(script)
    assert result.returncode == 1
    assert "both a source marker and a pending line" in result.stderr


def test_marker_that_belongs_to_no_site_fails(tmp_path):
    stray = "/// cli-parity-gap: stray-gap. Nothing here begins a row.\nfunc helper() {}\n"
    script = make_repo(
        tmp_path,
        {"Stray.swift": stray},
        {"PinTests.swift": 'func testPin() { assertCLIParityGap(nil, id: "stray-gap") }\n'},
        baseline=1,
    )
    result = run(script)
    assert result.returncode == 1
    assert "belongs to no begin site" in result.stderr


def test_forwarding_begin_wrapper_is_not_a_site(tmp_path):
    script = make_repo(tmp_path, {"Reporting.swift": FORWARDER}, {}, baseline=0)
    result = run(script)
    assert result.returncode == 0, result.stderr
    assert "SITES 0" in run(script, "--print").stdout


WRAPPER_AND_CALLER = '''
final class DemoModel {
    func begin(title: String, detail: String, cliCommand: String?) -> UUID? {
        center.begin(title: title, detail: detail, operationType: .download, cliCommand: cliCommand)
    }

    func download() {
        _ = begin(title: "Demo", detail: "Downloading", cliCommand: nil)
    }
}
'''


def test_caller_of_a_forwarding_wrapper_is_a_site(tmp_path):
    script = make_repo(tmp_path, {"Demo.swift": WRAPPER_AND_CALLER}, {}, baseline=0)
    printed = run(script, "--print").stdout
    assert "SITES 1" in printed
    assert "Demo.swift:8 download parses untested" in printed
    result = run(script)
    assert result.returncode == 1
    assert "Demo.swift:8 (download) records cliCommand: nil with no" in result.stderr


GENERIC_SITE = '''
final class HaplotypeService {
    func run() {
        _ = center.begin(title: "Run", detail: "", operationType: .workflow, cliCommand: builtCommand())
    }
}
'''


def test_a_generic_function_name_needs_its_type_or_file_in_the_same_test(tmp_path):
    unrelated = "func testOther() { model.run(); _ = try RecordedCLICommand.parse(command) }\n"
    script = make_repo(tmp_path, {"Services/HaplotypeService.swift": GENERIC_SITE}, {"OtherTests.swift": unrelated}, baseline=0)
    result = run(script)
    assert result.returncode == 1
    assert "Services/HaplotypeService.swift:run holds a begin site" in result.stderr

    named_type = "func testRun() { HaplotypeService().run(); _ = try RecordedCLICommand.parse(command) }\n"
    (tmp_path / "Tests/LungfishAppTests/OtherTests.swift").write_text(named_type)
    assert run(script).returncode == 0

    named_file = "// HaplotypeService.swift\nfunc testRun() { service.run(); _ = try RecordedCLICommand.parse(command) }\n"
    (tmp_path / "Tests/LungfishAppTests/OtherTests.swift").write_text(named_file)
    assert run(script).returncode == 0


def test_update_lowers_the_baseline_and_refuses_to_raise_it(tmp_path):
    script = make_repo(
        tmp_path,
        {"Merge.swift": GAP_SITE},
        {"MergeTests.swift": GAP_TEST},
        baseline=3,
    )
    assert run(script, "--update").returncode == 0
    assert (tmp_path / "scripts/ratchets/cli-parity-gaps.baseline").read_text().strip() == "1"
    (tmp_path / "Sources/LungfishApp/Merge2.swift").write_text(
        GAP_SITE.replace("thing-merge", "thing-split").replace("beginMergeOperation", "beginSplitOperation")
    )
    result = run(script, "--update")
    assert result.returncode == 1
    assert "refusing to raise the baseline" in result.stderr


def test_update_refuses_to_grow_the_untested_list(tmp_path):
    script = make_repo(
        tmp_path,
        {"Import.swift": PARSING_SITE, "Merge.swift": GAP_SITE},
        {"MergeTests.swift": GAP_TEST},
        baseline=1,
        untested="Sources/LungfishApp/Other.swift:beginOther\n",
    )
    result = run(script, "--update")
    assert result.returncode == 1
    assert "refusing to add untested sites" in result.stderr


def test_update_refuses_untested_sites_when_the_list_is_empty(tmp_path):
    # Once every listed site is tested, the list may not grow again.
    script = make_repo(
        tmp_path,
        {"Import.swift": PARSING_SITE},
        {"Other.swift": "// nothing\n"},
        baseline=0,
        untested="# Begin sites whose function no App test names beside a command parse.\n",
    )
    result = run(script, "--update")
    assert result.returncode == 1
    assert "refusing to add untested sites: Sources/LungfishApp/Import.swift:beginImportOperation" in result.stderr
    untested = (tmp_path / "scripts/ratchets/cli-parity-gaps.untested").read_text()
    assert "beginImportOperation" not in untested


def test_update_refuses_untested_sites_when_the_list_is_missing(tmp_path):
    script = make_repo(tmp_path, {"Import.swift": PARSING_SITE}, {"Other.swift": "// nothing\n"}, baseline=0)
    result = run(script, "--update")
    assert result.returncode == 1
    assert "refusing to add untested sites" in result.stderr
    assert not (tmp_path / "scripts/ratchets/cli-parity-gaps.untested").exists()


SPLIT_SITE_REUSING_THE_MERGE_GAP = '''
extension Thing {
    /// Records no command.
    ///
    /// cli-parity-gap: thing-merge. No command splits things.
    static func beginSplitOperation(reporter: any OperationReporting) -> OperationStartResult {
        reporter.begin(title: "Split", detail: "", operationType: .bundleBuild, cliCommand: nil)
    }
}
'''

SPLIT_TEST = GAP_TEST.replace("Merge", "Split")


def test_a_new_site_that_reuses_a_gap_id_raises_the_value(tmp_path):
    # Each gap site counts, so a new nil row cannot hide behind an existing
    # marker ID.
    script = make_repo(
        tmp_path,
        {"Merge.swift": GAP_SITE, "Split.swift": SPLIT_SITE_REUSING_THE_MERGE_GAP},
        {"MergeTests.swift": GAP_TEST, "SplitTests.swift": SPLIT_TEST},
        baseline=1,
    )
    result = run(script)
    assert result.returncode == 1
    assert "2 CLI parity gaps, up from the baseline of 1" in result.stderr
    assert "TOTAL 2" in run(script, "--print").stdout
    result = run(script, "--update")
    assert result.returncode == 1
    assert "refusing to raise the baseline from 1 to 2" in result.stderr


SHARED_HELPER_SITE = '''
extension Thing {
    /// Records no command for either download kind.
    ///
    /// cli-parity-gap: thing-download-a. No command downloads kind A.
    /// cli-parity-gap: thing-download-b. No command downloads kind B.
    static func beginDownloadOperation(reporter: any OperationReporting) -> OperationStartResult {
        reporter.begin(title: "Download", detail: "", operationType: .download, cliCommand: nil)
    }
}
'''

SHARED_HELPER_TEST = '''
final class DownloadTests: XCTestCase {
    func testDownload() {
        Thing.beginDownloadOperation(reporter: reporter)
        assertCLIParityGap(item.cliCommand, id: "thing-download-a")
        assertCLIParityGap(item.cliCommand, id: "thing-download-b")
    }
}
'''


def test_a_shared_helper_counts_each_gap_it_carries(tmp_path):
    # One begin helper that serves two operations is two gaps, not one site.
    script = make_repo(
        tmp_path,
        {"Download.swift": SHARED_HELPER_SITE},
        {"DownloadTests.swift": SHARED_HELPER_TEST},
        baseline=2,
    )
    result = run(script)
    assert result.returncode == 0, result.stderr
    assert "2 gaps, at the baseline" in result.stdout
    printed = run(script, "--print").stdout
    assert "beginDownloadOperation gap thing-download-a,thing-download-b" in printed
    assert "SITES 1" in printed
    assert "TOTAL 2" in printed


def test_each_pending_line_counts(tmp_path):
    pending = (
        "import-batch Sources/LungfishApp/Import.swift:beginImportOperation L9\n"
        "import-batch Sources/LungfishApp/Import.swift:beginOtherImportOperation L9\n"
    )
    script = make_repo(
        tmp_path,
        {"Import.swift": PARSING_SITE},
        {"ImportTests.swift": PARSE_TEST},
        baseline=1,
        pending=pending,
    )
    result = run(script)
    assert result.returncode == 1
    assert "2 CLI parity gaps, up from the baseline of 1" in result.stderr


def test_print_lists_each_site_with_its_status(tmp_path):
    script = make_repo(
        tmp_path,
        {"Import.swift": PARSING_SITE, "Merge.swift": GAP_SITE, "Seed.swift": EXEMPT_SITE},
        {"ImportTests.swift": PARSE_TEST, "MergeTests.swift": GAP_TEST},
        baseline=1,
    )
    printed = run(script, "--print").stdout
    assert "beginImportOperation parses" in printed
    assert "beginMergeOperation gap thing-merge" in printed
    assert "beginSeedOperation exempt not-an-operation untested" in printed
    assert "SITES 3" in printed
    assert "TOTAL 1" in printed
