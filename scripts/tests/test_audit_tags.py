"""Tests for scripts/checks/audit-tags.py (architecture review R5).

Every test builds a throwaway repo layout in tmp_path and copies the script into it, so the
real tree is never scanned. Tag text is assembled at run time. This file therefore holds no
literal audit tag and the lint passes over its own source.
"""
import importlib.util
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
REPO = SCRIPTS.parent
SCRIPT = SCRIPTS / "checks" / "audit-tags.py"
REAL_ALLOWLIST = SCRIPTS / "checks" / "audit-tags.allowlist"

PREFIXES = ["ARC", "FEA", "GEN", "NEW", "PERF", "REC", "REL", "SCI", "SIMP", "TST", "UX", "WFL"]


def tag(prefix="GEN", number="04"):
    return f"{prefix}-{number}"


def entry(path, prefix="GEN", number="08"):
    """One allowlist line, `<path>:<tag>`."""
    return f"{path}:{tag(prefix, number)}\n"


def make_repo(tmp_path, files, allowlist=None):
    """Copy the script into tmp_path/scripts/checks and write `files` (relative path -> text or bytes)."""
    checks = tmp_path / "scripts" / "checks"
    checks.mkdir(parents=True, exist_ok=True)
    shutil.copy(SCRIPT, checks / SCRIPT.name)
    for rel, content in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")
    if allowlist is not None:
        (checks / "audit-tags.allowlist").write_text(allowlist, encoding="utf-8")
    return checks / SCRIPT.name


def run(script_path, *args):
    return subprocess.run([sys.executable, str(script_path), *args], capture_output=True, text=True)


def swift_with(line):
    return f"import Foundation\n\n{line}\nlet value = 1\n"


def load_module():
    spec = importlib.util.spec_from_file_location("audit_tags", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_tag_in_a_comment_fails_with_file_and_line(tmp_path):
    script = make_repo(tmp_path, {"Sources/A/A.swift": swift_with(f"// {tag()}: keep the rationale")})
    result = run(script)
    assert result.returncode == 1
    assert "Sources/A/A.swift:3" in result.stderr
    assert tag() in result.stderr


def test_clean_tree_passes(tmp_path):
    script = make_repo(
        tmp_path,
        {
            "Sources/A/A.swift": swift_with("// A self-contained sentence about the rule."),
            "Tests/ATests/ATests.swift": "import XCTest\n",
            "scripts/tool.py": "print('hello')\n",
        },
    )
    result = run(script)
    assert result.returncode == 0, result.stderr
    assert "no audit finding tags" in result.stdout


def test_look_alike_strings_pass(tmp_path):
    text = "\n".join(
        [
            "// Encoding is UTF-8 and the digest is SHA-256.",
            "// Licensed under GPL-3 with a BY-NC clause. The cell line is HSV-1.",
            "// A bare prefix such as GEN or NEW, or a prefix with no number, is not a tag.",
            "// Other hyphenated names such as LAB-12 and PRE-04 use no audit prefix.",
            "// A prefix inside a longer word, as in SUBSCI-04 or XGEN-04, is not a tag either.",
        ]
    )
    script = make_repo(tmp_path, {"Sources/A/A.swift": text + "\n"})
    result = run(script)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("prefix", PREFIXES)
def test_every_audit_prefix_is_caught(tmp_path, prefix):
    script = make_repo(tmp_path, {"Sources/A/A.swift": swift_with(f"// ({tag(prefix, '12')})")})
    result = run(script)
    assert result.returncode == 1
    assert tag(prefix, "12") in result.stderr


def test_tag_with_a_sub_item_letter_is_caught(tmp_path):
    script = make_repo(tmp_path, {"Tests/ATests/ATests.swift": swift_with(f"// reported ({tag('WFL', '10')}e)")})
    result = run(script)
    assert result.returncode == 1
    assert "Tests/ATests/ATests.swift:3" in result.stderr


def test_two_tags_on_one_line_count_one_line(tmp_path):
    line = f"// {tag('SCI', '13')}/{tag('FEA', '09')}"
    script = make_repo(tmp_path, {"Sources/A/A.swift": swift_with(line)})
    result = run(script)
    assert result.returncode == 1
    assert "1 line(s) in 1 file(s)" in result.stderr


def test_python_and_shell_files_are_scanned(tmp_path):
    script = make_repo(
        tmp_path,
        {
            "scripts/tool.py": f'"""Docstring citing {tag("REL", "05")}."""\n',
            "scripts/run.sh": f"#!/bin/bash\n# {tag('TST', '02')}\n",
        },
    )
    result = run(script)
    assert result.returncode == 1
    assert "scripts/tool.py:1" in result.stderr
    assert "scripts/run.sh:2" in result.stderr


def test_allowlisted_tag_passes(tmp_path):
    files = {"Sources/A/A.swift": swift_with(f'let note = "{tag("GEN", "08")}: exported text"')}
    script = make_repo(tmp_path, files, allowlist=entry("Sources/A/A.swift"))
    result = run(script)
    assert result.returncode == 0, result.stderr
    assert "1 allowlisted" in result.stdout
    assert "matches no tag" not in result.stdout


def test_one_entry_covers_every_occurrence_of_its_tag(tmp_path):
    text = swift_with(f'let first = "{tag("GEN", "02")}: first"') + f'let second = "{tag("GEN", "02")}: second"\n'
    script = make_repo(tmp_path, {"Sources/A/A.swift": text}, allowlist=entry("Sources/A/A.swift", "GEN", "02"))
    result = run(script)
    assert result.returncode == 0, result.stderr
    assert "1 allowlisted" in result.stdout


def test_allowlist_exempts_only_the_listed_file(tmp_path):
    files = {
        "Sources/A/A.swift": swift_with(f'let note = "{tag("GEN", "08")}: exported text"'),
        "Sources/B/B.swift": swift_with(f"// {tag('GEN', '08')}: the same tag in another file"),
    }
    script = make_repo(tmp_path, files, allowlist=entry("Sources/A/A.swift"))
    result = run(script)
    assert result.returncode == 1
    assert "Sources/B/B.swift:3" in result.stderr
    assert "Sources/A/A.swift" not in result.stderr


def test_allowlist_exempts_only_the_listed_tag(tmp_path):
    text = swift_with(f'let note = "{tag("GEN", "08")}: exported text"') + f"// {tag('GEN', '02')}: a new comment\n"
    script = make_repo(tmp_path, {"Sources/A/A.swift": text}, allowlist=entry("Sources/A/A.swift"))
    result = run(script)
    assert result.returncode == 1
    assert "Sources/A/A.swift:5" in result.stderr
    assert "Sources/A/A.swift:3" not in result.stderr
    assert "1 line(s) in 1 file(s)" in result.stderr


def test_a_line_with_a_listed_and_an_unlisted_tag_fails(tmp_path):
    line = f"// {tag('GEN', '08')} and {tag('GEN', '02')}"
    script = make_repo(tmp_path, {"Sources/A/A.swift": swift_with(line)}, allowlist=entry("Sources/A/A.swift"))
    result = run(script)
    assert result.returncode == 1
    assert "Sources/A/A.swift:3" in result.stderr


def test_allowlist_entry_matches_the_whole_tag_including_a_sub_item_letter(tmp_path):
    files = {"Tests/ATests/ATests.swift": swift_with(f"// ({tag('WFL', '10')}b)")}
    short = make_repo(tmp_path / "short", files, allowlist=entry("Tests/ATests/ATests.swift", "WFL", "10"))
    assert run(short).returncode == 1
    exact = make_repo(tmp_path / "exact", files, allowlist=entry("Tests/ATests/ATests.swift", "WFL", "10b"))
    result = run(exact)
    assert result.returncode == 0, result.stderr


def test_stale_allowlist_entries_are_reported_but_pass(tmp_path):
    allowlist = entry("Sources/A/A.swift") + entry("Sources/Gone/Gone.swift", "GEN", "02")
    script = make_repo(tmp_path, {"Sources/A/A.swift": swift_with("// Clean now.")}, allowlist=allowlist)
    result = run(script)
    assert result.returncode == 0, result.stderr
    assert f"Sources/A/A.swift:{tag('GEN', '08')} matches no tag" in result.stdout
    assert f"Sources/Gone/Gone.swift:{tag('GEN', '02')} matches no tag" in result.stdout


def test_an_entry_for_a_tag_that_left_the_file_is_stale_while_a_different_tag_still_fails(tmp_path):
    files = {"Sources/A/A.swift": swift_with(f"// {tag('GEN', '02')}: a comment")}
    script = make_repo(tmp_path, files, allowlist=entry("Sources/A/A.swift"))
    result = run(script)
    assert result.returncode == 1
    assert f"Sources/A/A.swift:{tag('GEN', '08')} matches no tag" in result.stdout
    assert "Sources/A/A.swift:3" in result.stderr


def test_allowlist_comments_and_blank_lines_are_ignored(tmp_path):
    files = {"Sources/A/A.swift": swift_with(f"// {tag()}")}
    allowlist = "# a comment\n\n" + entry("Sources/A/A.swift", "GEN", "04") + "   # an indented comment\n"
    script = make_repo(tmp_path, files, allowlist=allowlist)
    result = run(script)
    assert result.returncode == 0, result.stderr


MALFORMED_ENTRIES = [
    "Sources/A/A.swift",
    "Sources/A/A.swift:",
    "Sources/A/A.swift:   ",
    f":{tag()}",
    "Sources/A/A.swift:a reason in prose",
    f"Sources/A/A.swift:{tag()} and a reason",
    "Sources/A/A.swift:UTF-8",
    "Sources/A/A.swift:GEN-",
]


@pytest.mark.parametrize("line", MALFORMED_ENTRIES)
def test_malformed_allowlist_entry_exits_two(tmp_path, line):
    script = make_repo(tmp_path, {"Sources/A/A.swift": "let x = 1\n"}, allowlist=line + "\n")
    result = run(script)
    assert result.returncode == 2
    assert "expected `<path>:<tag>`" in result.stderr


def test_the_allowlist_file_itself_is_not_scanned(tmp_path):
    script = make_repo(
        tmp_path,
        {"Sources/A/A.swift": "let x = 1\n"},
        allowlist=entry("Sources/Gone/Gone.swift", "GEN", "02"),
    )
    allowlist_file = tmp_path / "scripts" / "checks" / "audit-tags.allowlist"
    assert tag("GEN", "02") in allowlist_file.read_text(encoding="utf-8")
    result = run(script)
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""


def test_the_allowlist_in_use_is_skipped_whatever_its_name(tmp_path):
    script = make_repo(tmp_path, {"Sources/A/A.swift": swift_with(f"// {tag()}")})
    custom = tmp_path / "scripts" / "checks" / "custom.list"
    custom.write_text(entry("Sources/A/A.swift", "GEN", "04"), encoding="utf-8")
    result = run(script, "--allowlist", str(custom))
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""


def test_only_sources_tests_and_scripts_are_scanned(tmp_path):
    script = make_repo(
        tmp_path,
        {
            "docs/note.md": f"{tag()} lives in docs, which the lint does not scan.\n",
            "Package.swift": f"// {tag()}\n",
        },
    )
    assert run(script).returncode == 0
    (tmp_path / "Tests").mkdir()
    (tmp_path / "Tests" / "T.swift").write_text(f"// {tag()}\n", encoding="utf-8")
    assert run(script).returncode == 1


def test_binary_files_and_build_directories_are_skipped(tmp_path):
    script = make_repo(
        tmp_path,
        {
            "Sources/A/blob.bin": b"\0\1\2" + tag().encode() + b"\0",
            "Sources/A/.build/gen.swift": f"// {tag()}\n",
            "Tests/node_modules/pkg/index.js": f"// {tag()}\n",
            "scripts/__pycache__/mod.py": f"# {tag()}\n",
        },
    )
    result = run(script)
    assert result.returncode == 0, result.stderr


def test_the_script_passes_when_it_sits_in_the_scanned_tree(tmp_path):
    script = make_repo(tmp_path, {"Sources/A/A.swift": "let x = 1\n"})
    assert (tmp_path / "scripts" / "checks" / "audit-tags.py").exists()
    result = run(script)
    assert result.returncode == 0, result.stderr


def test_root_and_allowlist_options(tmp_path):
    script = make_repo(tmp_path / "repo", {"Sources/A/A.swift": swift_with(f"// {tag()}")})
    other = tmp_path / "other.allowlist"
    other.write_text(entry("Sources/A/A.swift", "GEN", "04"), encoding="utf-8")
    result = run(script, "--root", str(tmp_path / "repo"), "--allowlist", str(other))
    assert result.returncode == 0, result.stderr


def test_the_real_allowlist_is_well_formed():
    entries = load_module().read_allowlist(REAL_ALLOWLIST)
    assert entries, "the allowlist records the tags that stay"
    for path, tags in entries.items():
        assert not path.startswith("/"), path
        assert (REPO / path).is_file(), f"{path} is listed but does not exist"
        assert tags, path


def test_the_real_allowlist_names_exactly_the_tags_its_files_still_hold():
    module = load_module()
    for path, listed in module.read_allowlist(REAL_ALLOWLIST).items():
        held = {found for _, _, tags in module.scan_file(REPO / path) for found in tags}
        assert held == listed, f"{path} holds {sorted(held)} but the allowlist names {sorted(listed)}"
