"""Tests for the one-file mode of scripts/release/scan-release-portability.py (--binary FILE).

The mode counts every forbidden string of the scanner's table in one built product, so a lane can check a
Release product in the time of one build. It prints one "label count" line per pattern in table order and
fails only on labels other than user-home and repository-root, which a SwiftPM binary carries in its debug
map. With --all-labels it fails on those two as well, the check for a file that ships as it is, such as the
app's Linux executor. Every test works on files of a few bytes in a temporary folder. The app-folder mode
keeps its own suite in test_release_artifact_receipt.py, and one case here pins that the new flag leaves it
as it was.

This is a unittest file, so a python3 without pytest runs it:
python3 -m unittest scripts/tests/test_scan_release_portability_binary.py
"""
import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
RELEASE = SCRIPTS / "release"
SCANNER = RELEASE / "scan-release-portability.py"
TRUSTED_SCRATCH = "/private/var/tmp/lungfish-release-swiftpm/uid-test/repository/commit"


def run_scanner(*arguments):
    return subprocess.run(
        [sys.executable, str(SCANNER), *arguments],
        capture_output=True, text=True, check=False,
    )


def write(folder, name, payload):
    path = folder / name
    path.write_bytes(payload)
    return path


def make_app(root, payload):
    binary = root / "Fixture.app" / "Contents" / "MacOS" / "fixture"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(payload)
    return root / "Fixture.app"


class ScanBinaryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.tmp_path = Path(temporary.name).resolve()
        # The scanner module is loaded by path since its file name holds hyphens, and it imports a helper from its
        # own folder, so that folder leads sys.path while the module loads.
        search_path = mock.patch.object(sys, "path", [str(RELEASE), *sys.path])
        search_path.start()
        self.addCleanup(search_path.stop)
        spec = importlib.util.spec_from_file_location("scan_release_portability_under_test", SCANNER)
        self.scanner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.scanner)

    def patch(self, name, value):
        patcher = mock.patch.object(self.scanner, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)

    def main_binary(self, *arguments):
        """The status and output lines of main_binary called in this process, which sees the patched table."""
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            status = self.scanner.main_binary(list(arguments))
        return status, captured.getvalue().splitlines()

    # ------------------------------------------------------------ counts, order and exit codes

    def test_a_clean_file_counts_zero_for_every_pattern_in_table_order(self):
        product = write(self.tmp_path, "clean", b"\xcf\xfa\xed\xfe\x00just bytes\x00")

        result = run_scanner("--binary", str(product))

        expected = [f"{label} 0" for _, label in self.scanner.FORBIDDEN_PATTERNS] + ["PASS portability binary"]
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), expected)
        self.assertEqual(result.stderr, "")

    def test_one_forbidden_string_is_counted_once_and_fails(self):
        product = write(self.tmp_path, "leak", b"\x00/private/tmp/build\x00")

        result = run_scanner("--binary", str(product))

        lines = result.stdout.splitlines()
        self.assertEqual(result.returncode, 1)
        self.assertIn("private-tmp 1", lines)
        self.assertEqual(sum(1 for line in lines if line.endswith(" 0")), len(self.scanner.FORBIDDEN_PATTERNS) - 1)
        self.assertEqual(lines[-1], "FAIL portability binary findings=1")

    def test_repeats_and_overlapping_matches_are_all_counted(self):
        payload = b"/var/folders/a\x00/var/folders/b\x00/var/folders/c\x00/.tmp/.tmp/"
        product = write(self.tmp_path, "repeats", payload)

        result = run_scanner("--binary", str(product))

        lines = result.stdout.splitlines()
        self.assertEqual(result.returncode, 1)
        self.assertIn("macos-temporary 3", lines)
        self.assertIn("temporary-directory 2", lines)
        self.assertEqual(lines[-1], "FAIL portability binary findings=5")

    def test_user_home_alone_is_counted_and_passes(self):
        product = write(self.tmp_path, "debugmap", b"/Users/a\x00/Users/b\x00/Users/c")

        result = run_scanner("--binary", str(product))

        lines = result.stdout.splitlines()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("user-home 3", lines)
        self.assertEqual(lines[-1], "PASS portability binary")

    def test_user_home_and_repository_root_are_counted_but_never_fail(self):
        self.patch("FORBIDDEN_PATTERNS", (
            (b"/Users/", "user-home"),
            (b"/srv/checkout", "repository-root"),
            (b"/var/folders/", "macos-temporary"),
        ))
        product = write(
            self.tmp_path, "debugmap", b"/Users/a\x00/Users/b\x00/srv/checkout/x\x00/srv/checkout/y\x00/srv/checkout/z"
        )

        status, lines = self.main_binary("--binary", str(product))

        self.assertEqual(status, 0)
        self.assertEqual(lines, ["user-home 2", "repository-root 3", "macos-temporary 0", "PASS portability binary"])

        product.write_bytes(product.read_bytes() + b"\x00/var/folders/q")

        status, lines = self.main_binary("--binary", str(product))

        self.assertEqual(status, 1)
        self.assertEqual(
            lines, ["user-home 2", "repository-root 3", "macos-temporary 1", "FAIL portability binary findings=1"]
        )

    # ------------------------------------------------------------ --all-labels, the check for a file that ships as it is

    def test_binary_all_labels_fails_on_user_home(self):
        product = write(self.tmp_path, "lungfish-executor", b"/Users/x")

        result = run_scanner("--binary", str(product), "--all-labels")

        lines = result.stdout.splitlines()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("user-home 1", lines)
        self.assertEqual(lines[-1], "FAIL portability binary findings=1")

    def test_binary_default_keeps_home_advisory(self):
        product = write(self.tmp_path, "lungfish-executor", b"/Users/x")

        result = run_scanner("--binary", str(product))

        lines = result.stdout.splitlines()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("user-home 1", lines)
        self.assertEqual(lines[-1], "PASS portability binary")

    def test_binary_all_labels_fails_on_repository_root_and_passes_a_clean_file(self):
        self.patch("FORBIDDEN_PATTERNS", ((b"/Users/", "user-home"), (b"/srv/checkout", "repository-root")))
        leaking = write(self.tmp_path, "leaking", b"/workspace/a\x00/srv/checkout/b\x00/srv/checkout/c")
        clean = write(self.tmp_path, "clean", b"/workspace/a\x00/swiftpm-build/b")

        leaking_status, leaking_lines = self.main_binary("--binary", str(leaking), "--all-labels")
        clean_status, clean_lines = self.main_binary("--binary", str(clean), "--all-labels")

        self.assertEqual(
            (leaking_status, leaking_lines),
            (1, ["user-home 0", "repository-root 2", "FAIL portability binary findings=2"]),
        )
        self.assertEqual((clean_status, clean_lines), (0, ["user-home 0", "repository-root 0", "PASS portability binary"]))

    # ------------------------------------------------------------ chunk boundaries

    def test_a_string_across_a_chunk_boundary_is_counted_once(self):
        self.patch("CHUNK_SIZE", 16)
        self.patch("FORBIDDEN_PATTERNS", ((b"/var/folders/", "macos-temporary"),))

        for offset in range(0, 36):
            with self.subTest(offset=offset):
                product = write(self.tmp_path, "edge", b"." * offset + b"/var/folders/" + b"." * (64 - offset))

                self.assertEqual(self.scanner.count_patterns(product), [("macos-temporary", 1)])

    def test_many_strings_over_many_chunks_are_all_counted(self):
        self.patch("CHUNK_SIZE", 16)
        self.patch("FORBIDDEN_PATTERNS", ((b"/var/folders/", "macos-temporary"),))
        product = write(self.tmp_path, "many", b"/var/folders/." * 10)

        self.assertEqual(self.scanner.count_patterns(product), [("macos-temporary", 10)])

    def test_overlapping_matches_over_small_chunks_are_all_counted(self):
        self.patch("CHUNK_SIZE", 4)
        self.patch("FORBIDDEN_PATTERNS", ((b"/.tmp/", "temporary-directory"),))
        product = write(self.tmp_path, "overlap", b"/.tmp/.tmp/.tmp/")

        self.assertEqual(self.scanner.count_patterns(product), [("temporary-directory", 3)])

    def test_a_string_across_the_real_one_mebibyte_chunk_is_counted_once(self):
        padding = b"\x01" * (self.scanner.CHUNK_SIZE - 5)
        product = write(self.tmp_path, "big", padding + b"/var/folders/" + b"\x01" * 10)

        result = run_scanner("--binary", str(product))

        self.assertIn("macos-temporary 1", result.stdout.splitlines())

    # ------------------------------------------------------------ what the mode refuses

    def test_a_folder_a_symlink_and_a_missing_path_are_refused(self):
        target = write(self.tmp_path, "target", b"bytes")
        (self.tmp_path / "folder").mkdir()
        (self.tmp_path / "link").symlink_to(target)

        for kind, argument in (("folder", "folder"), ("symlink", "link"), ("missing", "absent")):
            with self.subTest(kind=kind):
                result = run_scanner("--binary", str(self.tmp_path / argument))

                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertTrue(result.stderr.startswith("portability scan error: "), result.stderr)

    def test_the_flag_needs_no_fallback_path_and_cannot_join_the_app_arguments(self):
        product = write(self.tmp_path, "clean", b"bytes")
        app = make_app(self.tmp_path, b"bytes")

        alone = run_scanner("--binary", str(product))
        mixed = run_scanner("--binary", str(product), str(app), "--allowed-swiftpm-fallback", TRUSTED_SCRATCH)

        self.assertEqual(alone.returncode, 0, alone.stderr)
        self.assertEqual(mixed.returncode, 2)
        self.assertEqual(mixed.stdout, "")

    # ------------------------------------------------------------ the app-folder mode as it was

    def test_the_app_folder_mode_keeps_its_arguments_output_and_exit_codes(self):
        clean = make_app(self.tmp_path / "clean", b"mach-o\x00tail")
        dirty = make_app(self.tmp_path / "dirty", b"mach-o\x00/Users/alice/work\x00tail")

        without_fallback = run_scanner(str(clean))
        passed = run_scanner(str(clean), "--allowed-swiftpm-fallback", TRUSTED_SCRATCH)
        failed = run_scanner(str(dirty), "--allowed-swiftpm-fallback", TRUSTED_SCRATCH)

        self.assertEqual(without_fallback.returncode, 2)
        self.assertIn("--allowed-swiftpm-fallback", without_fallback.stderr)
        self.assertEqual((passed.returncode, passed.stdout, passed.stderr), (0, "PASS portability\n", ""))
        self.assertEqual(failed.returncode, 1)
        self.assertEqual(failed.stdout, "Contents/MacOS/fixture:7:user-home\nFAIL portability findings=1 shown=1\n")


if __name__ == "__main__":
    unittest.main()
