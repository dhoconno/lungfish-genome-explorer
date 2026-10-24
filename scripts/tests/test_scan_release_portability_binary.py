"""Tests for the one-file mode of scripts/release/scan-release-portability.py (--binary FILE).

The mode counts every forbidden string of the scanner's table in one built product, so a lane can check a
Release product in the time of one build. It prints one "label count" line per pattern in table order and
fails only on labels other than user-home and repository-root, which a SwiftPM binary carries in its debug
map. Every test works on files of a few bytes in tmp_path. The app-folder mode keeps its own suite in
test_release_artifact_receipt.py, and one case here pins that the new flag leaves it as it was.
"""
import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
RELEASE = SCRIPTS / "release"
SCANNER = RELEASE / "scan-release-portability.py"
TRUSTED_SCRATCH = "/private/var/tmp/lungfish-release-swiftpm/uid-test/repository/commit"


@pytest.fixture
def scanner(monkeypatch):
    """The scanner module, loaded by path since its file name holds hyphens and it imports a helper
    from its own folder."""
    monkeypatch.syspath_prepend(str(RELEASE))
    spec = importlib.util.spec_from_file_location("scan_release_portability_under_test", SCANNER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_scanner(*arguments):
    return subprocess.run(
        [sys.executable, str(SCANNER), *arguments],
        capture_output=True, text=True, check=False,
    )


def write(tmp_path, name, payload):
    path = tmp_path / name
    path.write_bytes(payload)
    return path


def make_app(root, payload):
    binary = root / "Fixture.app" / "Contents" / "MacOS" / "fixture"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(payload)
    return root / "Fixture.app"


# ------------------------------------------------------------ counts, order and exit codes

def test_a_clean_file_counts_zero_for_every_pattern_in_table_order(tmp_path, scanner):
    product = write(tmp_path, "clean", b"\xcf\xfa\xed\xfe\x00just bytes\x00")

    result = run_scanner("--binary", str(product))

    expected = [f"{label} 0" for _, label in scanner.FORBIDDEN_PATTERNS] + ["PASS portability binary"]
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == expected
    assert result.stderr == ""


def test_one_forbidden_string_is_counted_once_and_fails(tmp_path, scanner):
    product = write(tmp_path, "leak", b"\x00/private/tmp/build\x00")

    result = run_scanner("--binary", str(product))

    lines = result.stdout.splitlines()
    assert result.returncode == 1
    assert "private-tmp 1" in lines
    assert sum(1 for line in lines if line.endswith(" 0")) == len(scanner.FORBIDDEN_PATTERNS) - 1
    assert lines[-1] == "FAIL portability binary findings=1"


def test_repeats_and_overlapping_matches_are_all_counted(tmp_path):
    payload = b"/var/folders/a\x00/var/folders/b\x00/var/folders/c\x00/.tmp/.tmp/"
    product = write(tmp_path, "repeats", payload)

    result = run_scanner("--binary", str(product))

    lines = result.stdout.splitlines()
    assert result.returncode == 1
    assert "macos-temporary 3" in lines
    assert "temporary-directory 2" in lines
    assert lines[-1] == "FAIL portability binary findings=5"


def test_user_home_alone_is_counted_and_passes(tmp_path):
    product = write(tmp_path, "debugmap", b"/Users/a\x00/Users/b\x00/Users/c")

    result = run_scanner("--binary", str(product))

    lines = result.stdout.splitlines()
    assert result.returncode == 0, result.stdout
    assert "user-home 3" in lines
    assert lines[-1] == "PASS portability binary"


def test_user_home_and_repository_root_are_counted_but_never_fail(tmp_path, scanner, monkeypatch, capsys):
    table = (
        (b"/Users/", "user-home"),
        (b"/srv/checkout", "repository-root"),
        (b"/var/folders/", "macos-temporary"),
    )
    monkeypatch.setattr(scanner, "FORBIDDEN_PATTERNS", table)
    product = write(
        tmp_path, "debugmap", b"/Users/a\x00/Users/b\x00/srv/checkout/x\x00/srv/checkout/y\x00/srv/checkout/z"
    )

    status = scanner.main_binary(["--binary", str(product)])

    assert status == 0
    assert capsys.readouterr().out.splitlines() == [
        "user-home 2", "repository-root 3", "macos-temporary 0", "PASS portability binary",
    ]

    product.write_bytes(product.read_bytes() + b"\x00/var/folders/q")

    status = scanner.main_binary(["--binary", str(product)])

    assert status == 1
    assert capsys.readouterr().out.splitlines() == [
        "user-home 2", "repository-root 3", "macos-temporary 1", "FAIL portability binary findings=1",
    ]


# ------------------------------------------------------------ --all-labels, the check for a file that ships as it is

def test_binary_all_labels_fails_on_user_home(tmp_path):
    product = write(tmp_path, "lungfish-executor", b"/Users/x")

    result = run_scanner("--binary", str(product), "--all-labels")

    lines = result.stdout.splitlines()
    assert result.returncode == 1, result.stdout
    assert "user-home 1" in lines
    assert lines[-1] == "FAIL portability binary findings=1"


def test_binary_default_keeps_home_advisory(tmp_path):
    product = write(tmp_path, "lungfish-executor", b"/Users/x")

    result = run_scanner("--binary", str(product))

    lines = result.stdout.splitlines()
    assert result.returncode == 0, result.stdout
    assert "user-home 1" in lines
    assert lines[-1] == "PASS portability binary"


def test_binary_all_labels_fails_on_repository_root_and_passes_a_clean_file(tmp_path, scanner, monkeypatch, capsys):
    table = ((b"/Users/", "user-home"), (b"/srv/checkout", "repository-root"))
    monkeypatch.setattr(scanner, "FORBIDDEN_PATTERNS", table)
    leaking = write(tmp_path, "leaking", b"/workspace/a\x00/srv/checkout/b\x00/srv/checkout/c")
    clean = write(tmp_path, "clean", b"/workspace/a\x00/swiftpm-build/b")

    leaking_status = scanner.main_binary(["--binary", str(leaking), "--all-labels"])
    leaking_lines = capsys.readouterr().out.splitlines()
    clean_status = scanner.main_binary(["--binary", str(clean), "--all-labels"])
    clean_lines = capsys.readouterr().out.splitlines()

    assert (leaking_status, leaking_lines) == (
        1, ["user-home 0", "repository-root 2", "FAIL portability binary findings=2"])
    assert (clean_status, clean_lines) == (0, ["user-home 0", "repository-root 0", "PASS portability binary"])


# ------------------------------------------------------------ chunk boundaries

@pytest.mark.parametrize("offset", range(0, 36))
def test_a_string_across_a_chunk_boundary_is_counted_once(tmp_path, scanner, monkeypatch, offset):
    monkeypatch.setattr(scanner, "CHUNK_SIZE", 16)
    monkeypatch.setattr(scanner, "FORBIDDEN_PATTERNS", ((b"/var/folders/", "macos-temporary"),))
    product = write(tmp_path, "edge", b"." * offset + b"/var/folders/" + b"." * (64 - offset))

    assert scanner.count_patterns(product) == [("macos-temporary", 1)]


def test_many_strings_over_many_chunks_are_all_counted(tmp_path, scanner, monkeypatch):
    monkeypatch.setattr(scanner, "CHUNK_SIZE", 16)
    monkeypatch.setattr(scanner, "FORBIDDEN_PATTERNS", ((b"/var/folders/", "macos-temporary"),))
    product = write(tmp_path, "many", b"/var/folders/." * 10)

    assert scanner.count_patterns(product) == [("macos-temporary", 10)]


def test_overlapping_matches_over_small_chunks_are_all_counted(tmp_path, scanner, monkeypatch):
    monkeypatch.setattr(scanner, "CHUNK_SIZE", 4)
    monkeypatch.setattr(scanner, "FORBIDDEN_PATTERNS", ((b"/.tmp/", "temporary-directory"),))
    product = write(tmp_path, "overlap", b"/.tmp/.tmp/.tmp/")

    assert scanner.count_patterns(product) == [("temporary-directory", 3)]


def test_a_string_across_the_real_one_mebibyte_chunk_is_counted_once(tmp_path, scanner):
    padding = b"\x01" * (scanner.CHUNK_SIZE - 5)
    product = write(tmp_path, "big", padding + b"/var/folders/" + b"\x01" * 10)

    result = run_scanner("--binary", str(product))

    assert "macos-temporary 1" in result.stdout.splitlines()


# ------------------------------------------------------------ what the mode refuses

@pytest.mark.parametrize("kind", ["folder", "symlink", "missing"])
def test_a_folder_a_symlink_and_a_missing_path_are_refused(tmp_path, kind):
    target = write(tmp_path, "target", b"bytes")
    (tmp_path / "folder").mkdir()
    (tmp_path / "link").symlink_to(target)
    argument = {"folder": "folder", "symlink": "link", "missing": "absent"}[kind]

    result = run_scanner("--binary", str(tmp_path / argument))

    assert result.returncode == 2
    assert result.stdout == ""
    assert result.stderr.startswith("portability scan error: ")


def test_the_flag_needs_no_fallback_path_and_cannot_join_the_app_arguments(tmp_path):
    product = write(tmp_path, "clean", b"bytes")
    app = make_app(tmp_path, b"bytes")

    alone = run_scanner("--binary", str(product))
    mixed = run_scanner("--binary", str(product), str(app), "--allowed-swiftpm-fallback", TRUSTED_SCRATCH)

    assert alone.returncode == 0, alone.stderr
    assert mixed.returncode == 2
    assert mixed.stdout == ""


# ------------------------------------------------------------ the app-folder mode as it was

def test_the_app_folder_mode_keeps_its_arguments_output_and_exit_codes(tmp_path):
    clean = make_app(tmp_path / "clean", b"mach-o\x00tail")
    dirty = make_app(tmp_path / "dirty", b"mach-o\x00/Users/alice/work\x00tail")

    without_fallback = run_scanner(str(clean))
    passed = run_scanner(str(clean), "--allowed-swiftpm-fallback", TRUSTED_SCRATCH)
    failed = run_scanner(str(dirty), "--allowed-swiftpm-fallback", TRUSTED_SCRATCH)

    assert without_fallback.returncode == 2
    assert "--allowed-swiftpm-fallback" in without_fallback.stderr
    assert (passed.returncode, passed.stdout, passed.stderr) == (0, "PASS portability\n", "")
    assert failed.returncode == 1
    assert failed.stdout == "Contents/MacOS/fixture:7:user-home\nFAIL portability findings=1 shown=1\n"
