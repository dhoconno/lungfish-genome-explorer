"""Tests for scripts/refactoring/verify_pure_move.py over throwaway git repositories.

Run from the repository root:
    /opt/homebrew/bin/python3 -m unittest scripts/tests/test_verify_pure_move.py
"""
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

VERIFY = Path(__file__).resolve().parents[1] / "refactoring" / "verify_pure_move.py"


class Repo:
    """A throwaway git repository whose commits the verifier reads."""

    def __init__(self, root):
        self.root = Path(root)
        self.git("init", "-q")

    def git(self, *args):
        done = subprocess.run(
            ["git", "-C", str(self.root), "-c", "user.name=Test", "-c", "user.email=test@example.com",
             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args],
            check=True, capture_output=True, text=True)
        return done.stdout.strip()

    def commit(self, files):
        for name, text in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(textwrap.dedent(text).lstrip("\n"), encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "commit")
        return self.git("rev-parse", "HEAD")


class VerifierCase(unittest.TestCase):
    def run_case(self, before, after, *flags):
        """Commit `before`, commit `after` on top of it, and run the verifier on the two commits."""
        with tempfile.TemporaryDirectory() as root:
            repo = Repo(root)
            base = repo.commit(before)
            head = repo.commit(after)
            done = subprocess.run([sys.executable, str(VERIFY), *flags, root, base, head],
                                  capture_output=True, text=True)
            return done.returncode, done.stdout, done.stderr


class MoveCheckTests(VerifierCase):
    WIDGET = """
        final class Widget {}

        extension Widget {
            func keep() {
                stay()
            }

            func moved() {
                first()
                second()
                third()
            }
        }
        """

    def test_move_with_wrappers_passes(self):
        after = {"Old.swift": """
            final class Widget {}

            extension Widget {
                func keep() {
                    stay()
                }
            }
            """, "New.swift": """
            // The header comment of a new file is ignored.
            extension Widget {
                func moved() {
                    first()
                    second()
                    third()
                }
            }
            """}
        code, out, _ = self.run_case({"Old.swift": self.WIDGET}, after)
        self.assertEqual(code, 0, out)
        self.assertIn("PURE-MOVE OK", out)
        self.assertIn("INFO wrapper added x1: extension Widget {", out)
        self.assertIn("INFO wrapper added x1: }", out)

    def test_block_split_over_two_files_passes(self):
        before = {"Big.swift": """
            func keep() {
                stay()
            }

            func alpha() -> Int {
                return 1
            }

            func beta() -> Int {
                return 2
            }
            """}
        after = {"Big.swift": """
            func keep() {
                stay()
            }
            """, "Alpha.swift": """
            func alpha() -> Int {
                return 1
            }
            """, "Beta.swift": """
            func beta() -> Int {
                return 2
            }
            """}
        code, out, _ = self.run_case(before, after)
        self.assertEqual(code, 0, out)
        self.assertIn("PURE-MOVE OK", out)
        self.assertNotIn("RUN-BREAK", out)

    def test_two_swapped_statements_fail(self):
        before = {"Body.swift": """
            func run() {
                prepare()
                first()
                second()
                finish()
            }
            """}
        after = {"Body.swift": """
            func run() {
                prepare()
                second()
                first()
                finish()
            }
            """}
        code, out, _ = self.run_case(before, after)
        self.assertEqual(code, 1, out)
        self.assertIn("RUN-BREAK", out)
        self.assertIn("NOT A PURE MOVE", out)
        self.assertNotIn("ADDED-NOT-REMOVED", out, "the multisets are equal, only the run check fails")

    def test_testable_import_line_is_ignored(self):
        before = {"Tests/WidgetTests.swift": """
            @testable import LungfishWorkflow
            import XCTest

            final class WidgetTests: XCTestCase {
                func testOne() {
                    XCTAssertTrue(true)
                }
            }
            """}
        after = {"Tests/WidgetTests.swift": """
            @testable import LungfishWorkflowTwelveS
            @testable import LungfishCore
            import XCTest

            final class WidgetTests: XCTestCase {
                func testOne() {
                    XCTAssertTrue(true)
                }
            }
            """}
        code, out, _ = self.run_case(before, after)
        self.assertEqual(code, 0, out)
        self.assertIn("PURE-MOVE OK", out)


class AccessOnlyTests(VerifierCase):
    PANEL = """
        final class Panel {
            @objc private func tapped() {}
            private(set) var count = 0
            override private func layout() {}
            private nonisolated static func shared() {}
            fileprivate func helper() {}
            private func inner() {}
        }
        """

    def test_access_only_passes_attribute_and_set_forms(self):
        after = {"Panel.swift": """
            final class Panel {
                @objc func tapped() {}
                var count = 0
                override func layout() {}
                nonisolated static func shared() {}
                func helper() {}
                package func inner() {}
            }
            """}
        code, out, _ = self.run_case({"Panel.swift": self.PANEL}, after, "--access-only")
        self.assertEqual(code, 0, out)
        self.assertIn("ACCESS-ONLY OK 6 widened", out)

    def test_access_only_fails_a_logic_edit_and_a_narrowing(self):
        base = """
            final class Panel {
                private func tapped() { run() }
                func shown() {}
                private func hidden() {}
            }
            """
        cases = {
            "more than the access word changed": """
                final class Panel {
                    func tapped() { run(1) }
                    func shown() {}
                    private func hidden() {}
                }
                """,
            "narrower access word": """
                final class Panel {
                    private func tapped() { run() }
                    private func shown() {}
                    private func hidden() {}
                }
                """,
            "public or open as a new word": """
                final class Panel {
                    private func tapped() { run() }
                    func shown() {}
                    public func hidden() {}
                }
                """,
            "1 added lines do not pair": """
                final class Panel {
                    private func tapped() { run() }
                    func shown() {}
                    func extra() {}
                    private func hidden() {}
                }
                """,
        }
        for reason, text in cases.items():
            with self.subTest(reason=reason):
                code, out, _ = self.run_case({"Panel.swift": base}, {"Panel.swift": text}, "--access-only")
                self.assertEqual(code, 1, out)
                self.assertIn(reason, out)
                self.assertIn("NOT AN ACCESS-ONLY WIDENING", out)

    def test_access_only_fails_an_added_file(self):
        before = {"Panel.swift": self.PANEL}
        after = {"Panel.swift": self.PANEL, "Other.swift": "func other() {}\n"}
        code, out, _ = self.run_case(before, after, "--access-only")
        self.assertEqual(code, 1, out)
        self.assertIn("a widening commit only modifies files", out)


class MoreMoveCheckTests(VerifierCase):
    OLD = """
        final class Widget {}

        func moved() {
            first()
            second()
        }
        """

    def test_split_of_one_extension_at_a_mark_into_two_files_passes(self):
        before = {"Big.swift": """
            final class Widget {}

            extension Widget {
                // MARK: Alpha
                func alpha() {
                    one()
                    two()
                }

                // MARK: Beta
                func beta() {
                    three()
                    four()
                }
            }
            """}
        after = {"Big.swift": """
            final class Widget {}

            extension Widget {
                // MARK: Alpha
                func alpha() {
                    one()
                    two()
                }
            }
            """, "Beta.swift": """
            extension Widget {
                // MARK: Beta
                func beta() {
                    three()
                    four()
                }
            }
            """}
        code, out, _ = self.run_case(before, after)
        self.assertEqual(code, 0, out)
        self.assertIn("INFO wrapper added x1: extension Widget {", out)

    def test_unbalanced_wrapper_fails(self):
        after = {"Old.swift": "final class Widget {}\n", "New.swift": """
            extension Widget {
                func moved() {
                    first()
                    second()
                }
            """}
        code, out, _ = self.run_case({"Old.swift": self.OLD}, after)
        self.assertEqual(code, 1, out)
        self.assertIn("ADDED-NOT-REMOVED x1: extension Widget {", out)

    def test_wrapper_of_an_unrelated_type_fails(self):
        after = {"Old.swift": "final class Widget {}\n", "New.swift": """
            extension Stranger {
                func moved() {
                    first()
                    second()
                }
            }
            """}
        code, out, _ = self.run_case({"Old.swift": self.OLD}, after)
        self.assertEqual(code, 1, out)
        self.assertIn("ADDED-NOT-REMOVED x1: extension Stranger {", out)
        self.assertNotIn("INFO wrapper", out)

    def test_access_word_change_in_a_move_fails(self):
        before = {"Old.swift": """
            final class Widget {
                private func moved() {
                    first()
                    second()
                }
            }
            """}
        after = {"Old.swift": "final class Widget {\n}\n", "New.swift": """
            extension Widget {
                func moved() {
                    first()
                    second()
                }
            }
            """}
        code, out, _ = self.run_case(before, after)
        self.assertEqual(code, 1, out)
        self.assertIn("ADDED-NOT-REMOVED x1: func moved() {", out)
        self.assertIn("REMOVED-NOT-ADDED x1: private func moved() {", out)

    def test_package_swift_edit_is_a_note_and_not_checked(self):
        before = {"Package.swift": "let package = 1\n", "Old.swift": self.OLD}
        after = {"Package.swift": "let package = 2\n", "Old.swift": "final class Widget {}\n",
                 "New.swift": "func moved() {\n    first()\n    second()\n}\n"}
        code, out, _ = self.run_case(before, after)
        self.assertEqual(code, 0, out)
        self.assertIn("NOTE non-Swift M Package.swift", out)

    def test_unknown_flag_is_refused_and_nothing_relaxes_the_move_check(self):
        done = subprocess.run([sys.executable, str(VERIFY), "--access", ".", "HEAD~1", "HEAD"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)
        self.assertIn("usage:", done.stderr)


if __name__ == "__main__":
    unittest.main()
