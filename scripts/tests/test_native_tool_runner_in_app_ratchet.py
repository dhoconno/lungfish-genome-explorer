"""Tests for the native-tool-runner-in-app ratchet (Phase 2.9, lane A13).

Every test builds a throwaway repo layout in tmp_path and copies the script under test into it,
so nothing mutates the real repository. Three tests read the real checkout and the hook
generator, as test_tool_identity_ratchet.py does.
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
SCRIPT = SCRIPTS / "ratchets" / "native-tool-runner-in-app.sh"
REPO = SCRIPTS.parent

NAME = "files_naming_native_tool_runner"
APP = "Sources/LungfishApp/Services/"
USE = "let r = NativeToolRunner.shared"


def swift(*lines):
    """A Swift file whose first line is an import, so a site on the next line is line 2."""
    return "import Foundation\n" + "".join(line + "\n" for line in lines)


def make_repo(tmp_path, files):
    dest_dir = tmp_path / "scripts" / "ratchets"
    dest_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy(SCRIPT, dest_dir / SCRIPT.name)
    shutil.copy(SCRIPT.with_name("ratchet_baseline.py"), dest_dir / "ratchet_baseline.py")
    for rel, text in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return dest_dir / SCRIPT.name


def run(script_path, *args):
    return subprocess.run([sys.executable, str(script_path), *args], capture_output=True, text=True)


def baseline_text(tmp_path):
    return (tmp_path / "scripts/ratchets/native-tool-runner-in-app.baseline").read_text()


def recorded_count(tmp_path):
    for line in baseline_text(tmp_path).splitlines():
        name, _, number = line.rpartition(" ")
        if name == NAME:
            return int(number)
    raise AssertionError("the baseline records no count")


def count_of(tmp_path, *lines):
    """The count the ratchet records for one App file made of `lines`."""
    script = make_repo(tmp_path, {APP + "A.swift": swift(*lines)})
    assert run(script, "--update").returncode == 0
    return recorded_count(tmp_path)


def test_counts_files_not_occurrences(tmp_path):
    script = make_repo(
        tmp_path,
        {
            APP + "A.swift": swift(USE, USE),
            APP + "B.swift": swift("let c: NativeToolRunner = .shared"),
            APP + "C.swift": swift("let d = 1"),
        },
    )
    assert run(script, "--update").returncode == 0
    assert recorded_count(tmp_path) == 2
    (tmp_path / APP / "A.swift").write_text(swift(USE, USE, USE))
    result = run(script)
    assert result.returncode == 0
    assert f"2 {NAME}, at the recorded baseline." in result.stdout


def test_a_new_file_that_names_it_fails_with_the_fix_text(tmp_path):
    script = make_repo(tmp_path, {APP + "A.swift": swift(USE)})
    assert run(script, "--update").returncode == 0
    (tmp_path / APP / "B.swift").write_text(swift(USE))
    result = run(script)
    assert result.returncode == 1
    assert f"2 for {NAME}, up from the recorded baseline of 1" in result.stderr
    assert "lungfish-cli" in result.stderr
    assert "--print" in result.stderr


@pytest.mark.parametrize(
    "lines",
    [
        ["// " + USE],
        ["/// Runs samtools through NativeToolRunner."],
        ["let a = 1 // NativeToolRunner in a trailing comment"],
        ["/* NativeToolRunner */"],
        ["/** doc block", " * NativeToolRunner", " */"],
        ["/* first line", "   NativeToolRunner on a middle line", "*/"],
        ["/* outer /* inner */ NativeToolRunner after the inner end */"],
        ['let u = "https://example.org" // NativeToolRunner'],
        ['let p = #"C:\\"#; // NativeToolRunner'],
        ['let s = "\\(x)"; // NativeToolRunner'],
    ],
)
def test_comments_are_ignored(tmp_path, lines):
    assert count_of(tmp_path, *lines) == 0


@pytest.mark.parametrize(
    "lines",
    [
        ["/* note */ " + USE],
        ["/* first line", "last line */ " + USE],
        ["let a = 1 // note", USE],
        ["/* outer /* inner */ still a comment */ " + USE],
        ['let u = "https://example.org"; ' + USE],
        ['let s = "/*"', USE],
        ['let s = "say \\"hi\\" // not a comment"; ' + USE],
        ['let s = "\\(d["k"]) // text"; ' + USE],
        ['let a = """', "  see https://example.org // not a comment", '  """; ' + USE],
        ['let p = #"C:\\"#; ' + USE],
        ['let s = "a \\" // b"; ' + USE],
        ['let s = "\\(f("//"))"; ' + USE],
        ['let a = """', "  glob /* pattern", '  """', USE],
        ['let s = "NativeToolRunner failed"'],
    ],
)
def test_code_and_string_text_outside_comments_count(tmp_path, lines):
    assert count_of(tmp_path, *lines) == 1


@pytest.mark.parametrize(
    "line, counted",
    [
        ("let e: NativeToolRunnerError? = nil", 0),
        ("let m = MockNativeToolRunner()", 0),
        ("let r = LungfishWorkflow.NativeToolRunner.shared", 1),
        ("let v = NativeToolRunner.bundledVersions", 1),
        ("func f(runner: NativeToolRunner = .shared) {}", 1),
    ],
)
def test_only_the_whole_identifier_counts(tmp_path, line, counted):
    assert count_of(tmp_path, line) == counted


def test_only_swift_files_under_the_app_folder_are_counted(tmp_path):
    script = make_repo(
        tmp_path,
        {
            "Sources/LungfishWorkflow/Native/NativeToolRunner.swift": swift("public actor NativeToolRunner {}"),
            "Sources/LungfishCLI/Commands/Tool.swift": swift(USE),
            "Sources/LungfishAppExtras/A.swift": swift(USE),
            "Tests/LungfishAppTests/AppTests.swift": swift(USE),
            APP + "Notes.md": "NativeToolRunner\n",
            APP + "Plain.swift": swift("let a = 1"),
        },
    )
    assert run(script, "--update").returncode == 0
    assert recorded_count(tmp_path) == 0


def test_under_baseline_passes_and_suggests_update(tmp_path):
    script = make_repo(tmp_path, {APP + "A.swift": swift(USE)})
    assert run(script, "--update").returncode == 0
    (tmp_path / APP / "A.swift").write_text(swift("let a = 1"))
    result = run(script)
    assert result.returncode == 0
    assert f"Down from baseline for {NAME}" in result.stdout
    assert "--update" in result.stdout


def test_missing_baseline_fails(tmp_path):
    script = make_repo(tmp_path, {APP + "A.swift": swift("let a = 1")})
    result = run(script)
    assert result.returncode == 1
    assert "no baseline recorded" in result.stderr


def test_update_writes_the_header_and_the_count(tmp_path):
    script = make_repo(tmp_path, {APP + "A.swift": swift(USE)})
    result = run(script, "--update")
    assert result.returncode == 0
    assert f"Updated baseline: 1 {NAME}." in result.stdout
    header, entry = baseline_text(tmp_path).splitlines()
    assert header.startswith("# native-tool-runner-in-app baseline")
    assert entry == f"{NAME} 1"


def test_print_lists_each_site_and_never_fails(tmp_path):
    script = make_repo(tmp_path, {APP + "A.swift": swift(USE, "// " + USE, USE)})
    result = run(script, "--print")
    assert result.returncode == 0
    assert result.stdout.splitlines() == [
        f"{APP}A.swift:2: NativeToolRunner",
        f"{APP}A.swift:4: NativeToolRunner",
        f"TOTAL {NAME} 1",
    ]


def test_real_repo_is_at_or_under_its_baseline():
    result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, cwd=REPO)
    assert result.returncode == 0, result.stderr


def test_real_baseline_has_the_update_header_and_the_one_count(tmp_path):
    script = make_repo(tmp_path, {APP + "A.swift": swift("let a = 1")})
    assert run(script, "--update").returncode == 0
    generated_header = baseline_text(tmp_path).splitlines()[0]
    real = SCRIPT.with_suffix(".baseline").read_text().splitlines()
    assert real[0] == generated_header
    assert len(real) == 2
    assert re.fullmatch(rf"{NAME} [0-9]+", real[1])


def test_the_pre_push_hook_runs_the_ratchet_after_tool_identity_and_before_the_gate():
    hook = (SCRIPTS / "install-git-hooks.sh").read_text()
    call = 'python3 "$REPO_ROOT/scripts/ratchets/native-tool-runner-in-app.sh"'
    assert hook.count(call) == 1
    ratchet = hook.index(call)
    assert hook.index('"$REPO_ROOT/scripts/ratchets/tool-identity.sh"') < ratchet
    assert ratchet < hook.index('"$REPO_ROOT/scripts/checks/doc-path-references.py"')
    assert ratchet < hook.index('"$REPO_ROOT/scripts/full-suite-gate.sh"')


def test_the_hook_block_has_the_message_style_of_the_other_ratchet_blocks():
    hook = (SCRIPTS / "install-git-hooks.sh").read_text()
    block = (
        r'echo "pre-push: checking the native-tool-runner-in-app ratchet \(use --no-verify to skip\)\.\.\."\n'
        r'if ! python3 "\$REPO_ROOT/scripts/ratchets/native-tool-runner-in-app\.sh"; then\n'
        r'    echo "pre-push: native-tool-runner-in-app ratchet FAILED \([^"]+\) \u2014 push aborted\. '
        r'Use --no-verify to bypass\." >&2\n'
        r"    exit 1\n"
        r"fi\n"
    )
    assert re.search(block, hook)
    summary = next(
        line for line in hook.splitlines()
        if line.startswith('echo "It runs the ') and " ratchets," in line
    )
    named = summary[len('echo "It runs the '):].split(" ratchets,")[0]
    assert "native-tool-runner-in-app" in re.split(r", | and ", named)
