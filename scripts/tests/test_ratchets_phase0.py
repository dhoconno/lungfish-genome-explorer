"""Tests for the Phase 0 ratchets and checks (architecture program, Lane E).

Every test builds a throwaway repo layout in tmp_path and copies the script
under test into it, so nothing mutates the real repository.
"""
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
RATCHETS = SCRIPTS / "ratchets"
CHECKS = SCRIPTS / "checks"


def make_repo(tmp_path, script, files):
    """Copy `script` (a Path under scripts/) into tmp_path at the same relative place."""
    dest_dir = tmp_path / "scripts" / script.parent.name
    dest_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy(script, dest_dir / script.name)
    for rel, text in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return dest_dir / script.name


def run(script_path, *args):
    return subprocess.run(
        [sys.executable, str(script_path), *args], capture_output=True, text=True
    )


def swift_lines(n):
    return "let x = 0\n" * n


# ---------------------------------------------------------------- file-size

FILE_SIZE = RATCHETS / "file-size.sh"


def test_file_size_new_oversize_file_fails(tmp_path):
    script = make_repo(tmp_path, FILE_SIZE, {"Sources/A/Small.swift": swift_lines(800)})
    assert run(script, "--update").returncode == 0
    assert run(script).returncode == 0
    (tmp_path / "Sources/A/Big.swift").write_text(swift_lines(801))
    result = run(script)
    assert result.returncode == 1
    assert "Sources/A/Big.swift" in result.stderr


def test_file_size_baselined_file_may_shrink_but_not_grow(tmp_path):
    script = make_repo(tmp_path, FILE_SIZE, {"Sources/A/Big.swift": swift_lines(900)})
    assert run(script, "--update").returncode == 0
    assert (tmp_path / "scripts/ratchets/file-size.baseline").read_text().count("Sources/A/Big.swift 900") == 1
    assert run(script).returncode == 0
    (tmp_path / "Sources/A/Big.swift").write_text(swift_lines(850))
    assert run(script).returncode == 0
    (tmp_path / "Sources/A/Big.swift").write_text(swift_lines(901))
    assert run(script).returncode == 1


def test_file_size_missing_baseline_fails(tmp_path):
    script = make_repo(tmp_path, FILE_SIZE, {"Sources/A/Small.swift": swift_lines(3)})
    assert run(script).returncode == 1


def test_file_size_print_lists_oversize(tmp_path):
    script = make_repo(tmp_path, FILE_SIZE, {"Sources/A/Big.swift": swift_lines(810)})
    result = run(script, "--print")
    assert result.returncode == 0
    assert "Sources/A/Big.swift 810" in result.stdout
    assert "TOTAL 1" in result.stdout


# --------------------------------------------------------- concurrency-hatches

HATCHES = RATCHETS / "concurrency-hatches.sh"
HATCH_SRC = (
    "final class A: @unchecked Sendable {}\n"
    "nonisolated(unsafe) static var cache = 0\n"
    "func f() { MainActor.assumeIsolated { } }\n"
    "// MainActor.assumeIsolated in a comment is ignored\n"
)


def test_hatches_counts_each_kind_and_passes_at_baseline(tmp_path):
    script = make_repo(tmp_path, HATCHES, {"Sources/A/A.swift": HATCH_SRC})
    assert run(script, "--update").returncode == 0
    baseline = (tmp_path / "scripts/ratchets/concurrency-hatches.baseline").read_text()
    assert "MainActor.assumeIsolated 1" in baseline
    assert "@unchecked Sendable 1" in baseline
    assert "nonisolated(unsafe) 1" in baseline
    assert "nonisolated(unsafe) static var 1" in baseline
    assert run(script).returncode == 0


def test_hatches_new_use_fails(tmp_path):
    script = make_repo(tmp_path, HATCHES, {"Sources/A/A.swift": HATCH_SRC})
    assert run(script, "--update").returncode == 0
    (tmp_path / "Sources/A/B.swift").write_text("struct B: @unchecked Sendable {}\n")
    result = run(script)
    assert result.returncode == 1
    assert "@unchecked Sendable" in result.stderr


def test_hatches_static_var_counted_separately(tmp_path):
    script = make_repo(tmp_path, HATCHES, {"Sources/A/A.swift": "let a = 1\n"})
    assert run(script, "--update").returncode == 0
    (tmp_path / "Sources/A/B.swift").write_text("nonisolated(unsafe) static var x = 0\n")
    assert run(script).returncode == 1


def test_hatches_removal_passes(tmp_path):
    script = make_repo(tmp_path, HATCHES, {"Sources/A/A.swift": HATCH_SRC})
    assert run(script, "--update").returncode == 0
    (tmp_path / "Sources/A/A.swift").write_text("let a = 1\n")
    result = run(script)
    assert result.returncode == 0
    assert "--update" in result.stdout


# ------------------------------------------------------ source-text-assertions

SRC_TEXT = RATCHETS / "source-text-assertions.sh"
SOURCE_TEST = (
    'let src = try String(contentsOf: root.appendingPathComponent("Sources/LungfishApp/X.swift"))\n'
    'XCTAssertTrue(src.contains("foo"))\n'
    'XCTAssertTrue(src.contains("bar"))\n'
)
OTHER_TEST = 'XCTAssertTrue(name.contains("foo"))\n'


def test_source_text_counts_only_source_reading_files(tmp_path):
    script = make_repo(
        tmp_path,
        SRC_TEXT,
        {"Tests/AppTests/SourceTests.swift": SOURCE_TEST, "Tests/AppTests/Plain.swift": OTHER_TEST},
    )
    result = run(script, "--print")
    assert "TOTAL 2" in result.stdout
    assert "Plain.swift" not in result.stdout


def test_source_text_new_assertion_fails(tmp_path):
    script = make_repo(tmp_path, SRC_TEXT, {"Tests/AppTests/SourceTests.swift": SOURCE_TEST})
    assert run(script, "--update").returncode == 0
    assert run(script).returncode == 0
    (tmp_path / "Tests/AppTests/SourceTests.swift").write_text(
        SOURCE_TEST + 'XCTAssertTrue(src.contains("baz"))\n'
    )
    assert run(script).returncode == 1


def test_source_text_fewer_assertions_pass(tmp_path):
    script = make_repo(tmp_path, SRC_TEXT, {"Tests/AppTests/SourceTests.swift": SOURCE_TEST})
    assert run(script, "--update").returncode == 0
    (tmp_path / "Tests/AppTests/SourceTests.swift").write_text(OTHER_TEST)
    assert run(script).returncode == 0


# ------------------------------------------------------- doc-path-references

DOC_REFS = CHECKS / "doc-path-references.py"
DOC_FILES = {
    "Sources/LungfishApp/App/AppDelegate.swift": "",
    "Sources/LungfishApp/Views/Thing.swift": "",
    "Sources/LungfishApp/AGENTS.md": "Entry: `App/AppDelegate.swift`, `Views/Thing.swift`.\n",
    "AGENTS.md": "See Sources/LungfishApp/App/AppDelegate.swift and AppDelegate.swift.\n",
    "docs/contracts/X.md": "Placeholder `Foo<Name>.swift` and `Sources/*/Bar.swift` are skipped.\n",
}


def test_doc_refs_resolve_ok(tmp_path):
    script = make_repo(tmp_path, DOC_REFS, DOC_FILES)
    result = run(script)
    assert result.returncode == 0, result.stderr


def test_doc_refs_broken_full_path_fails(tmp_path):
    files = dict(DOC_FILES, **{"AGENTS.md": "See Sources/LungfishApp/App/Gone.swift.\n"})
    script = make_repo(tmp_path, DOC_REFS, files)
    result = run(script)
    assert result.returncode == 1
    assert "AGENTS.md:1: Sources/LungfishApp/App/Gone.swift" in result.stderr


def test_doc_refs_broken_bare_name_fails(tmp_path):
    files = dict(DOC_FILES, **{"docs/architecture/A.md": "line one\nSee Missing.swift here.\n"})
    script = make_repo(tmp_path, DOC_REFS, files)
    result = run(script)
    assert result.returncode == 1
    assert "docs/architecture/A.md:2: Missing.swift" in result.stderr


def test_doc_refs_module_relative_path_must_exist(tmp_path):
    files = dict(DOC_FILES, **{"Sources/LungfishApp/AGENTS.md": "See `App/Nope.swift`.\n"})
    script = make_repo(tmp_path, DOC_REFS, files)
    assert run(script).returncode == 1


def test_doc_refs_allowlist_suppresses(tmp_path):
    files = dict(DOC_FILES, **{"docs/contracts/X.md": "A new `HypotheticalFile.swift` example.\n"})
    script = make_repo(tmp_path, DOC_REFS, files)
    assert run(script).returncode == 1
    (tmp_path / "scripts/checks/doc-path-references.allowlist").write_text(
        "HypotheticalFile.swift  # example in a contract\n"
    )
    assert run(script).returncode == 0


def test_doc_refs_specialists_reported_not_enforced(tmp_path):
    files = dict(DOC_FILES, **{"agents/specialists/01.md": "Old `Removed.swift`.\n"})
    script = make_repo(tmp_path, DOC_REFS, files)
    result = run(script)
    assert result.returncode == 0
    assert "agents/specialists/01.md:1: Removed.swift" in result.stdout


# ------------------------------------------------------ duplicate-public-types

DUP = CHECKS / "duplicate-public-types.py"


def test_duplicate_types_unique_passes(tmp_path):
    script = make_repo(
        tmp_path,
        DUP,
        {
            "Sources/A/A.swift": "public struct Alpha {}\npublic enum Beta {}\n",
            "Sources/B/B.swift": "public struct Gamma {}\n    public struct Nested {}\ninternal struct Alpha {}\n",
        },
    )
    assert run(script).returncode == 0


def test_duplicate_types_across_targets_fail(tmp_path):
    script = make_repo(
        tmp_path,
        DUP,
        {
            "Sources/A/A.swift": "public enum SequencingPlatform {}\n",
            "Sources/B/B.swift": "@frozen public final class SequencingPlatform {}\n",
        },
    )
    result = run(script)
    assert result.returncode == 1
    assert "SequencingPlatform" in result.stderr
    assert "Sources/A/A.swift:1" in result.stderr


def test_duplicate_types_allowlist_suppresses_and_reports_stale(tmp_path):
    script = make_repo(
        tmp_path,
        DUP,
        {
            "Sources/A/A.swift": "public enum SequencingPlatform {}\n",
            "Sources/B/B.swift": "public enum SequencingPlatform {}\n",
        },
    )
    (tmp_path / "scripts/checks/duplicate-public-types.allowlist").write_text(
        "SequencingPlatform  # R15\nGone  # was resolved\n"
    )
    result = run(script)
    assert result.returncode == 0
    assert "Gone is no longer a duplicate" in result.stdout


def test_duplicate_types_same_name_within_one_target_is_not_flagged(tmp_path):
    script = make_repo(
        tmp_path,
        DUP,
        {
            "Sources/A/A.swift": "public struct Same {}\n",
            "Sources/A/Sub/B.swift": "public struct Same {}\n",
        },
    )
    assert run(script).returncode == 0


# ------------------------------------------------------------ the real repo

def test_real_repo_passes_every_check():
    repo = SCRIPTS.parent
    for script in (
        RATCHETS / "file-size.sh",
        RATCHETS / "concurrency-hatches.sh",
        RATCHETS / "source-text-assertions.sh",
        CHECKS / "doc-path-references.py",
        CHECKS / "duplicate-public-types.py",
    ):
        result = subprocess.run(
            [sys.executable, str(script)], capture_output=True, text=True, cwd=repo
        )
        assert result.returncode == 0, f"{script.name}: {result.stderr}"


# ------------------------------------------------------------ hook wiring

def test_installed_hook_lists_new_checks_before_the_gate(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    scripts_dir = tmp_path / "scripts"
    scripts_dir.mkdir()
    shutil.copy(SCRIPTS / "install-git-hooks.sh", scripts_dir / "install-git-hooks.sh")
    result = subprocess.run(
        ["/bin/bash", str(scripts_dir / "install-git-hooks.sh")],
        cwd=tmp_path, capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr
    hook = (tmp_path / ".git" / "hooks" / "pre-push").read_text()
    names = [
        "unchecked-operation-start.sh",
        "shared-slider-control.sh",
        "features-yaml-entry-points.py",
        "compile-embedded-python.py",
        "file-size.sh",
        "concurrency-hatches.sh",
        "source-text-assertions.sh",
        "doc-path-references.py",
        "duplicate-public-types.py",
        "full-suite-gate.sh",
    ]
    positions = [hook.index(n) for n in names]
    assert positions == sorted(positions)
