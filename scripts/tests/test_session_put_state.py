"""Tests of scripts/session/put_state.py. They use temporary files only."""
import importlib.util
import io
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "session" / "put_state.py"
spec = importlib.util.spec_from_file_location("session_put_state", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

NOTES = "# Job notes\n\n## STATE 2026-11-12 03:27 (newest)\nold 1\nold 2\n\n## Continuation guide\nkeep me\n"
FORM = "Spawn form: You run as <type> on <model> at effort <level>."


class PutStateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.dir = Path(temporary.name)

    def put(self, notes, state, *extra):
        notes_path, state_path = self.dir / "notes.md", self.dir / "state.md"
        notes_path.write_text(notes, encoding="utf-8")
        state_path.write_text(state, encoding="utf-8")
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = module.main([str(notes_path), str(state_path), *extra])
        return code, out.getvalue(), err.getvalue(), notes_path.read_text(encoding="utf-8")

    def test_replaces_the_block_and_keeps_the_next_heading(self):
        code, out, _, text = self.put(NOTES, "## STATE 2026-11-12 04:00\nnew 1\nnew 2\n")
        self.assertEqual(code, 0)
        self.assertEqual(text, "# Job notes\n\n## STATE 2026-11-12 04:00\n" + FORM + "\nnew 1\nnew 2\n\n## Continuation guide\nkeep me\n")
        written = ("## STATE 2026-11-12 04:00\n" + FORM + "\nnew 1\nnew 2\n").encode()
        self.assertIn("STATE block written, %d bytes" % len(written), out)

    def test_puts_a_heading_above_text_that_has_none(self):
        _, _, _, text = self.put(NOTES, "just text\n\n")
        self.assertEqual(text, "# Job notes\n\n## STATE\n" + FORM + "\njust text\n\n## Continuation guide\nkeep me\n")

    def test_replaces_a_block_that_runs_to_the_end_of_the_file(self):
        _, _, _, text = self.put("# T\n\n## Intro\nhi\n\n## STATE\nold\n", "## STATE\nnew\n")
        self.assertEqual(text, "# T\n\n## Intro\nhi\n\n## STATE\n" + FORM + "\nnew\n")

    def test_inserts_under_the_title_when_there_is_no_block(self):
        _, _, _, text = self.put("# T\n\n## Intro\nhi\n", "## STATE\nnew\n")
        self.assertEqual(text, "# T\n\n## STATE\n" + FORM + "\nnew\n\n## Intro\nhi\n")

    def test_replaces_only_the_first_block(self):
        _, _, _, text = self.put("# T\n## STATE a\nx\n## STATE b\ny\n", "## STATE c\nz\n")
        self.assertEqual(text, "# T\n## STATE c\n" + FORM + "\nz\n\n## STATE b\ny\n")

    def test_a_heading_that_only_starts_with_state_is_not_a_block(self):
        _, _, _, text = self.put("# T\n## STATEMENT\nx\n", "## STATE\nz\n")
        self.assertEqual(text, "# T\n\n## STATE\n" + FORM + "\nz\n\n## STATEMENT\nx\n")

    def test_the_limit_is_3072_bytes_of_the_whole_block_with_its_spawn_form_line(self):
        room = 3062 - len(FORM) - 1
        at_limit = "## STATE\n" + "a" * room
        code, out, _, text = self.put(NOTES, at_limit)
        self.assertEqual(code, 0)
        self.assertIn("STATE block written, 3072 bytes", out)
        self.assertIn("\n" + FORM + "\n" + "a" * room + "\n", text)
        code, _, err, text = self.put(NOTES, at_limit + "a")
        self.assertEqual(code, 2)
        self.assertIn("3073 bytes", err)
        self.assertEqual(text, NOTES)

    def test_a_state_that_holds_the_line_keeps_it_where_it_stands(self):
        state = "## STATE\nfirst\n" + FORM + "\nlast\n"
        _, _, _, text = self.put(NOTES, state)
        self.assertEqual(text, "# Job notes\n\n" + state + "\n## Continuation guide\nkeep me\n")

    def test_another_spawn_form_line_becomes_the_fixed_line_and_a_repeat_goes(self):
        state = "## STATE\nSpawn form: You run as <type> on <model>\nkeep\n  Spawn form: older\n" + FORM + "\n"
        _, _, _, text = self.put(NOTES, state)
        self.assertEqual(text, "# Job notes\n\n## STATE\n" + FORM + "\nkeep\n\n## Continuation guide\nkeep me\n")

    def test_a_second_run_with_the_written_block_changes_nothing(self):
        first = self.put(NOTES, "## STATE\nnew\n")[3]
        self.assertEqual(self.put(first, "## STATE\n" + FORM + "\nnew\n")[3], first)

    def test_a_state_of_only_a_heading_gets_the_line(self):
        _, _, _, text = self.put(NOTES, "## STATE\n")
        self.assertEqual(text, "# Job notes\n\n## STATE\n" + FORM + "\n\n## Continuation guide\nkeep me\n")

    def test_a_block_that_holds_the_line_fills_the_limit_without_a_second_copy(self):
        full = "## STATE\n" + FORM + "\n" + "a" * (3062 - len(FORM) - 1)
        self.assertEqual(len((full + "\n").encode()), 3072)
        code, _, _, text = self.put(NOTES, full)
        self.assertEqual((code, text.count(FORM)), (0, 1))

    def test_the_limit_counts_bytes_not_characters(self):
        code, _, err, text = self.put(NOTES, "## STATE\n" + "é" * 1600)
        self.assertEqual(code, 2)
        self.assertIn("over the limit of 3072", err)
        self.assertEqual(text, NOTES)

    def test_max_bytes_is_an_option(self):
        self.assertEqual(self.put(NOTES, "## STATE\n" + "a" * 100, "--max-bytes", "50")[0], 2)
        self.assertEqual(self.put(NOTES, "## STATE\n" + "a" * 100, "--max-bytes", "200")[0], 0)

    def test_an_empty_state_is_refused(self):
        code, _, err, text = self.put(NOTES, "\n\n")
        self.assertEqual(code, 2)
        self.assertIn("holds no text", err)
        self.assertEqual(text, NOTES)

    def test_a_missing_file_is_refused(self):
        err = io.StringIO()
        with redirect_stderr(err):
            code = module.main([str(self.dir / "none.md"), str(self.dir / "state.md")])
        self.assertEqual(code, 2)
        self.assertIn("cannot read", err.getvalue())

    def test_the_file_mode_is_kept_and_no_temporary_file_stays(self):
        notes_path = self.dir / "notes.md"
        notes_path.write_text(NOTES, encoding="utf-8")
        os.chmod(notes_path, 0o640)
        (self.dir / "state.md").write_text("## STATE\nnew\n", encoding="utf-8")
        with redirect_stdout(io.StringIO()):
            self.assertEqual(module.main([str(notes_path), str(self.dir / "state.md")]), 0)
        self.assertEqual(notes_path.stat().st_mode & 0o777, 0o640)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["notes.md", "state.md"])


if __name__ == "__main__":
    unittest.main()
