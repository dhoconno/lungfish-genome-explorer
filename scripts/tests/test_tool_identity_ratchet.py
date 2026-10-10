"""Tests for the tool-identity ratchet (Phase 2.5, lane G).

Every test builds a throwaway repo layout in tmp_path and copies the script under test into it,
so nothing mutates the real repository. Two tests read the real checkout and run the script
against it, as test_provenance_ratchets.py does.
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
SCRIPT = SCRIPTS / "ratchets" / "tool-identity.sh"
REPO = SCRIPTS.parent

NAMES = ("analysis_id_decisions", "tool_named_lookups", "unknown_version_fallbacks")
REGISTRY_FILE = "Sources/LungfishIO/Analysis/AnalysisToolRegistry.swift"


def swift(*lines):
    """A Swift file whose first line is an import, so a site on the next line is line 2."""
    return "import Foundation\n" + "".join(line + "\n" for line in lines)


def make_repo(tmp_path, files):
    dest_dir = tmp_path / "scripts" / "ratchets"
    dest_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy(SCRIPT, dest_dir / SCRIPT.name)
    for rel, text in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return dest_dir / SCRIPT.name


def run(script_path, *args):
    return subprocess.run([sys.executable, str(script_path), *args], capture_output=True, text=True)


def baseline_of(tmp_path):
    text = (tmp_path / "scripts/ratchets/tool-identity.baseline").read_text()
    entries = {}
    for line in text.splitlines():
        if line.strip() and not line.startswith("#"):
            name, _, number = line.rpartition(" ")
            entries[name] = int(number)
    return entries


def counts_of(tmp_path, line):
    script = make_repo(tmp_path, {"Sources/A/A.swift": swift(line)})
    assert run(script, "--update").returncode == 0
    return baseline_of(tmp_path)


SITES = {
    "analysis_id_decisions": 'if tool == "kraken2" { return }',
    "tool_named_lookups": "let t = try? ManagedToolLock.loadFromBundle().tool(named: id)",
    "unknown_version_fallbacks": 'let v = await runner.getToolVersion(tool) ?? "unknown"',
}


@pytest.mark.parametrize("name", NAMES)
def test_a_new_site_fails_with_its_own_fix_text(tmp_path, name):
    script = make_repo(tmp_path, {"Sources/A/A.swift": swift(SITES[name])})
    assert run(script, "--update").returncode == 0
    assert baseline_of(tmp_path)[name] == 1
    assert run(script).returncode == 0
    (tmp_path / "Sources/B").mkdir()
    (tmp_path / "Sources/B/B.swift").write_text(swift(SITES[name]), encoding="utf-8")
    result = run(script)
    assert result.returncode == 1
    assert f"2 for {name}, up from the recorded baseline of 1" in result.stderr
    assert "docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md" in result.stderr
    for other in NAMES:
        if other != name:
            assert f"for {other}," not in result.stderr


@pytest.mark.parametrize("name", NAMES)
def test_comments_are_ignored(tmp_path, name):
    script = make_repo(tmp_path, {"Sources/A/A.swift": swift("let a = 1")})
    assert run(script, "--update").returncode == 0
    site = SITES[name]
    (tmp_path / "Sources/A/A.swift").write_text(
        swift(f"// {site}", f"/// {site}", f"let a = 1 // {site}"), encoding="utf-8"
    )
    assert run(script).returncode == 0
    assert "Sources/A/A.swift" not in run(script, "--print").stdout


def test_the_registry_folder_is_exempt_for_id_decisions_only(tmp_path):
    script = make_repo(tmp_path, {"Sources/A/A.swift": swift("let a = 1")})
    assert run(script, "--update").returncode == 0
    (tmp_path / REGISTRY_FILE).parent.mkdir(parents=True)
    (tmp_path / REGISTRY_FILE).write_text(swift(SITES["analysis_id_decisions"]), encoding="utf-8")
    assert run(script).returncode == 0
    (tmp_path / REGISTRY_FILE).write_text(swift(SITES["tool_named_lookups"]), encoding="utf-8")
    assert run(script).returncode == 1


def test_a_folder_that_only_looks_like_the_registry_is_counted(tmp_path):
    script = make_repo(tmp_path, {"Sources/A/A.swift": swift("let a = 1")})
    assert run(script, "--update").returncode == 0
    path = tmp_path / "Sources/LungfishApp/Analysis/Other.swift"
    path.parent.mkdir(parents=True)
    path.write_text(swift(SITES["analysis_id_decisions"]), encoding="utf-8")
    result = run(script)
    assert result.returncode == 1
    assert "1 for analysis_id_decisions" in result.stderr


def test_under_baseline_passes_and_suggests_update(tmp_path):
    script = make_repo(tmp_path, {"Sources/A/A.swift": swift(SITES["tool_named_lookups"])})
    assert run(script, "--update").returncode == 0
    (tmp_path / "Sources/A/A.swift").write_text(swift("let a = 1"), encoding="utf-8")
    result = run(script)
    assert result.returncode == 0
    assert "Down from baseline for tool_named_lookups" in result.stdout
    assert "--update" in result.stdout


def test_missing_baseline_fails(tmp_path):
    script = make_repo(tmp_path, {"Sources/A/A.swift": swift("let a = 1")})
    result = run(script)
    assert result.returncode == 1
    assert "no baseline recorded" in result.stderr


def test_update_records_every_count_in_order(tmp_path):
    script = make_repo(tmp_path, {})
    assert run(script, "--update").returncode == 0
    lines = (tmp_path / "scripts/ratchets/tool-identity.baseline").read_text().splitlines()
    assert lines[0].startswith("#")
    assert [line.rpartition(" ")[0] for line in lines[1:]] == list(NAMES)
    assert run(script).returncode == 0


def test_print_lists_each_site_once_and_never_fails(tmp_path):
    script = make_repo(
        tmp_path,
        {"Sources/A/A.swift": swift(SITES["tool_named_lookups"]), "Sources/A/B.swift": swift("let a = 1", SITES["tool_named_lookups"])},
    )
    result = run(script, "--print")
    assert result.returncode == 0
    assert "Sources/A/A.swift:2: tool_named_lookups" in result.stdout
    assert "Sources/A/B.swift:3: tool_named_lookups" in result.stdout
    assert "TOTAL tool_named_lookups 2" in result.stdout


@pytest.mark.parametrize(
    ("line", "decisions"),
    [
        ('case "kraken2":', 1),
        ('case "kraken2", "bbmap":', 2),
        ('case "esviritu", "kraken2", "taxtriage": return 1', 3),
        ('if tool == "esviritu" {', 1),
        ('if tool != "esviritu" {', 1),
        ('if "esviritu" == tool {', 1),
        ('name.hasPrefix("kraken2-")', 1),
        ('name.hasPrefix("kraken2-batch-")', 1),
        ('name.hasSuffix("kraken2")', 1),
        ('case "classification": ', 1),
        ('case "nao-mgs":', 1),
        ('case "bwa-mem2":', 1),
        ('case "kraken2extra":', 0),
        ('case "bbtools":', 0),
        ('if tool == "bbtools" {', 0),
        ('case kraken2 = "kraken2"', 0),
        ('let name = "kraken2"', 0),
        ('args: ["kraken2", "build"]', 0),
        ('name.hasPrefix("my-kraken2")', 0),
        ('let s = "a == b"', 0),
    ],
)
def test_an_id_literal_counts_only_as_a_decision(tmp_path, line, decisions):
    assert counts_of(tmp_path, line)["analysis_id_decisions"] == decisions


@pytest.mark.parametrize(
    ("line", "counted"),
    [
        ("let t = lock.tool(named: id)", 1),
        ("let t = try? ManagedToolLock.loadFromBundle().tool(named: \"pysam\")", 1),
        ("public func tool(named name: String) -> Tool? {", 0),
        ("let t = lock.entry(id: id)", 0),
        ("let t = lock.tools(named: id)", 0),
    ],
)
def test_tool_named_counts_the_call_and_not_the_definition(tmp_path, line, counted):
    assert counts_of(tmp_path, line)["tool_named_lookups"] == counted


@pytest.mark.parametrize(
    ("line", "counted"),
    [
        ('let v = await runner.getToolVersion(tool) ?? "unknown"', 1),
        ('let v = await runner.getToolVersion(tool) ??"unknown"', 1),
        ('let v = await runner.getToolVersion(tool) ?? "n/a"', 0),
        ('let v = database.version ?? "unknown"', 0),
        ('let v = await runner.getToolVersion(tool)', 0),
    ],
)
def test_unknown_fallback_needs_a_tool_version_lookup(tmp_path, line, counted):
    assert counts_of(tmp_path, line)["unknown_version_fallbacks"] == counted


def test_a_slash_pair_inside_a_string_does_not_start_a_comment(tmp_path):
    line = 'let u = "https://x" ; if tool == "kraken2" {}'
    assert counts_of(tmp_path, line)["analysis_id_decisions"] == 1


def test_the_id_list_equals_the_registry():
    registry = (REPO / REGISTRY_FILE).read_text(encoding="utf-8")
    registry_ids = set(re.findall(r'AnalysisToolID\(rawValue: "([^"]+)"\)', registry))
    sys.path.insert(0, str(SCRIPT.parent))
    try:
        import importlib.machinery
        import importlib.util

        loader = importlib.machinery.SourceFileLoader("tool_identity_ratchet", str(SCRIPT))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
    finally:
        sys.path.pop(0)
    assert set(module.ANALYSIS_IDS) == registry_ids


def test_real_repo_is_at_or_under_its_baseline():
    result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, cwd=REPO)
    assert result.returncode == 0, result.stderr


def test_real_baseline_names_every_count_once():
    text = SCRIPT.with_suffix(".baseline").read_text()
    entries = [line.rpartition(" ") for line in text.splitlines() if line.strip() and not line.startswith("#")]
    assert [name for name, _, _ in entries] == list(NAMES)
    assert all(re.fullmatch(r"[0-9]+", number) for _, _, number in entries)


def test_the_pre_push_hook_runs_the_ratchet():
    hook = (SCRIPTS / "install-git-hooks.sh").read_text()
    assert 'python3 "$REPO_ROOT/scripts/ratchets/tool-identity.sh"' in hook
    ratchet = hook.index('"$REPO_ROOT/scripts/ratchets/tool-identity.sh"')
    assert hook.index('"$REPO_ROOT/scripts/ratchets/path-helpers.sh"') < ratchet
    assert ratchet < hook.index('"$REPO_ROOT/scripts/full-suite-gate.sh"')
