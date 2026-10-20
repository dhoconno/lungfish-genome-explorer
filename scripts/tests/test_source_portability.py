"""Tests for scripts/checks/source-portability.py, its pre-push entry and the lineagePath guard.

Every check test builds a throwaway repository layout in tmp_path and copies the check, the scanner and the
scanner's helper into it, so the real tree is read only by the tests that name it. Forbidden strings are
written into the throwaway Sources folder at run time, and this file lives outside Sources, so the check
never reads it.
"""
import importlib.util
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
REPO = SCRIPTS.parent
CHECK = SCRIPTS / "checks" / "source-portability.py"
SCANNER = SCRIPTS / "release" / "scan-release-portability.py"
SCANNER_HELPER = SCRIPTS / "release" / "release_cache_security.py"
INSTALLER = SCRIPTS / "install-git-hooks.sh"
LINEAGE = "Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope+LineageFocus.swift"
SPLIT_ROOTS = '["/var/", "/tmp/", "/etc/"]'
JOINED_ROOTS = '["/private/var/", "/private/tmp/", "/private/etc/"]'


def load_check():
    spec = importlib.util.spec_from_file_location("source_portability_under_test", CHECK)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def scanner_table():
    check = load_check()
    return check.forbidden_patterns(check.load_scanner(REPO))


TABLE = scanner_table()


def make_repo(tmp_path, files=None):
    """Copy the check, the scanner and its helper into tmp_path and write `files`
    (relative path -> text or bytes) under it. Sources always exists."""
    for source, folder in ((CHECK, "checks"), (SCANNER, "release"), (SCANNER_HELPER, "release")):
        destination = tmp_path / "scripts" / folder
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copy(source, destination / source.name)
    (tmp_path / "Sources").mkdir(exist_ok=True)
    for relative, content in (files or {}).items():
        path = tmp_path / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if isinstance(content, bytes) else content.encode("utf-8"))
    return tmp_path


def run_check(root):
    return subprocess.run(
        [sys.executable, str(root / "scripts" / "checks" / CHECK.name)],
        cwd=root, capture_output=True, text=True, check=False,
    )


# ------------------------------------------------------------ what the check reports

def test_a_tree_without_forbidden_literals_prints_nothing(tmp_path):
    root = make_repo(tmp_path, {"Sources/Mod/Clean.swift": 'let name = "lungfish"\n'})

    result = run_check(root)

    assert (result.returncode, result.stdout, result.stderr) == (0, "", "")


def test_a_hit_in_code_prints_path_line_and_label(tmp_path):
    root = make_repo(tmp_path, {
        "Sources/Mod/Leak.swift": 'import Foundation\n\nlet home = "/Users/alice/work"\n',
    })

    result = run_check(root)

    assert result.returncode == 1
    assert result.stdout == "Sources/Mod/Leak.swift:3: user-home\n"
    assert result.stderr == ""


@pytest.mark.parametrize(
    "pattern, label", TABLE, ids=[f"{index}-{label}" for index, (_, label) in enumerate(TABLE)]
)
def test_every_pattern_of_the_scanner_table_is_reported(tmp_path, pattern, label):
    root = make_repo(tmp_path, {"Sources/Mod/Table.swift": b'let path = "' + pattern + b'/tail"\n'})

    result = run_check(root)

    assert result.returncode == 1, result.stdout
    assert f"Sources/Mod/Table.swift:1: {label}\n" in result.stdout


def test_hits_are_sorted_and_a_line_with_two_labels_prints_both(tmp_path):
    root = make_repo(tmp_path, {
        "Sources/Zeta/Late.swift": 'let a = "DerivedData"\n',
        "Sources/Alpha/Early.swift": 'let ok = 1\nlet b = "/Users/alice/DerivedData"\n',
    })

    result = run_check(root)

    assert result.returncode == 1
    assert result.stdout == (
        "Sources/Alpha/Early.swift:2: user-home\n"
        "Sources/Alpha/Early.swift:2: derived-data\n"
        "Sources/Zeta/Late.swift:1: derived-data\n"
    )


# ------------------------------------------------------------ which lines and files count

def test_a_swift_comment_line_is_not_a_hit(tmp_path):
    text = (
        "// writes under /private/tmp/ on the build machine\n"
        "    /// see /Users/alice/work for the notes\n"
        "\t// DerivedData is not compiled\n"
        "let ok = 1\n"
    )
    root = make_repo(tmp_path, {"Sources/Mod/Comments.swift": text})

    result = run_check(root)

    assert (result.returncode, result.stdout, result.stderr) == (0, "", "")


def test_a_trailing_comment_after_code_still_counts(tmp_path):
    root = make_repo(tmp_path, {
        "Sources/Mod/Trail.swift": 'let home = "/Users/alice" // not a comment line\n',
    })

    result = run_check(root)

    assert result.returncode == 1
    assert result.stdout == "Sources/Mod/Trail.swift:1: user-home\n"


def test_a_resource_file_counts_every_line_even_one_that_starts_with_slashes(tmp_path):
    page = "<script>\n// /Users/alice/work\n</script>\n"
    root = make_repo(tmp_path, {"Sources/Mod/Resources/page.html": page})

    result = run_check(root)

    assert result.returncode == 1
    assert result.stdout == "Sources/Mod/Resources/page.html:2: user-home\n"


def test_a_binary_file_is_skipped(tmp_path):
    payload = b"\x7fELF\x00" + b"/Users/alice/work" + b"\x00"
    root = make_repo(tmp_path, {"Sources/Mod/Resources/tool": payload})

    result = run_check(root)

    assert (result.returncode, result.stdout, result.stderr) == (0, "", "")


def test_a_nul_after_the_first_8000_bytes_leaves_the_file_text(tmp_path):
    payload = b"x" * 7990 + b"\n/Users/alice\n\x00tail\n"
    root = make_repo(tmp_path, {"Sources/Mod/Resources/blob": payload})

    result = run_check(root)

    assert result.returncode == 1
    assert result.stdout == "Sources/Mod/Resources/blob:2: user-home\n"


def test_a_missing_sources_folder_is_an_error_and_not_a_pass(tmp_path):
    root = make_repo(tmp_path)
    shutil.rmtree(root / "Sources")

    result = run_check(root)

    assert result.returncode == 2
    assert result.stdout == ""
    assert "Sources" in result.stderr


# ------------------------------------------------------------ the table comes from the scanner

def test_a_pattern_added_to_the_scanner_table_is_checked(tmp_path, monkeypatch):
    check = load_check()
    scanner = check.load_scanner(REPO)
    added = scanner.FORBIDDEN_PATTERNS + ((b"/srv/build/", "build-server"),)
    monkeypatch.setattr(scanner, "FORBIDDEN_PATTERNS", added)
    root = make_repo(tmp_path, {"Sources/Mod/New.swift": 'let p = "/srv/build/x"\n'})

    assert check.find_hits(root, scanner) == [("Sources/Mod/New.swift", 1, "build-server")]


def test_the_script_reads_the_table_of_the_scanner_next_to_it(tmp_path):
    root = make_repo(tmp_path, {"Sources/Mod/New.swift": 'let p = "/srv/build/x"\n'})
    scanner = root / "scripts" / "release" / SCANNER.name
    text = scanner.read_text(encoding="utf-8")
    marker = '    (b"/Users/", "user-home"),\n'
    assert marker in text
    scanner.write_text(
        text.replace(marker, marker + '    (b"/srv/build/", "build-server"),\n'), encoding="utf-8"
    )

    result = run_check(root)

    assert result.returncode == 1
    assert result.stdout == "Sources/Mod/New.swift:1: build-server\n"


def test_the_dynamic_repository_root_entry_is_left_out(tmp_path, monkeypatch):
    check = load_check()
    scanner = check.load_scanner(REPO)
    table = ((b"/srv/checkout", "repository-root"), (b"/srv/build/", "build-server"))
    monkeypatch.setattr(scanner, "FORBIDDEN_PATTERNS", table)
    text = 'let a = "/srv/checkout/x"\nlet b = "/srv/build/y"\n'
    root = make_repo(tmp_path, {"Sources/Mod/Root.swift": text})

    assert check.find_hits(root, scanner) == [("Sources/Mod/Root.swift", 2, "build-server")]


# ------------------------------------------------------------ the real repository

def test_the_real_sources_folder_is_clean():
    result = run_check(REPO)

    assert (result.returncode, result.stdout, result.stderr) == (0, "", "")


# ------------------------------------------------------------ the lineagePath guard

def lineage_text():
    text = (REPO / LINEAGE).read_text(encoding="utf-8")
    assert SPLIT_ROOTS in text, "lineagePath changed shape, so update SPLIT_ROOTS and JOINED_ROOTS with it"
    return text


def test_lineage_path_as_committed_holds_no_forbidden_literal(tmp_path):
    root = make_repo(tmp_path, {LINEAGE: lineage_text()})

    result = run_check(root)

    assert (result.returncode, result.stdout, result.stderr) == (0, "", "")


def test_joining_the_roots_of_lineage_path_again_fails_with_private_tmp(tmp_path):
    joined = lineage_text().replace(SPLIT_ROOTS, JOINED_ROOTS)
    line = next(n for n, text in enumerate(joined.splitlines(), start=1) if JOINED_ROOTS in text)
    root = make_repo(tmp_path, {LINEAGE: joined})

    result = run_check(root)

    assert result.returncode == 1
    assert result.stdout == f"{LINEAGE}:{line}: private-tmp\n"


# ------------------------------------------------------------ hook wiring

def installed_hook(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    scripts_dir = tmp_path / "scripts"
    scripts_dir.mkdir()
    shutil.copy(INSTALLER, scripts_dir / INSTALLER.name)
    installed = subprocess.run(
        ["/bin/bash", str(scripts_dir / INSTALLER.name)],
        cwd=tmp_path, capture_output=True, text=True,
    )
    assert installed.returncode == 0, installed.stderr
    return (tmp_path / ".git" / "hooks" / "pre-push").read_text(encoding="utf-8")


def test_the_hook_runs_the_check_after_duplicate_public_types_and_before_the_gate(tmp_path):
    hook = installed_hook(tmp_path)

    names = ["duplicate-public-types.py", "source-portability.py", "publish.py", "full-suite-gate.sh"]
    positions = [hook.index(name) for name in names]
    assert positions == sorted(positions)
    assert hook.count("scripts/checks/source-portability.py") == 1


def test_the_hook_failure_message_names_the_scanner_and_a_label(tmp_path):
    hook = installed_hook(tmp_path)

    call = 'if ! python3 "$REPO_ROOT/scripts/checks/source-portability.py"; then'
    block = hook[hook.index(call):].split("\nfi\n", 1)[0]
    assert "scripts/release/scan-release-portability.py" in block
    assert "private-tmp" in block
    assert ">&2" in block
    assert "exit 1" in block
