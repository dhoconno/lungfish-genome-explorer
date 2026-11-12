"""Tests of scripts/session/agent_ended.py. They feed canned transcripts and an injected lsof."""
import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "session" / "agent_ended.py"
spec = importlib.util.spec_from_file_location("session_agent_ended", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

NOW = datetime(2026, 11, 12, 12, 0, 0, tzinfo=timezone.utc)
TEXT = [{"type": "text", "text": "done"}]
TOOL = [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]
RESULT = [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]


def entry(kind, blocks, ago):
    when = (NOW - timedelta(seconds=ago)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    return json.dumps({"type": kind, "timestamp": when, "message": {"role": kind, "content": blocks}})


def other(kind, ago):
    return json.dumps({"type": kind, "timestamp": (NOW - timedelta(seconds=ago)).strftime("%Y-%m-%dT%H:%M:%S.000Z")})


class AgentEndedTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.dir = Path(os.path.realpath(temporary.name))

    def check(self, lines, *extra, lsof=None):
        path = self.dir / "agent.jsonl"
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        out = io.StringIO()
        with redirect_stdout(out):
            code = module.main([str(path), *extra], now=NOW, lsof=lsof)
        return code, out.getvalue().strip()

    def test_a_final_message_that_is_old_enough_has_ended(self):
        self.assertEqual(self.check([entry("user", "go", 300), entry("assistant", TEXT, 120)]), (0, "ENDED"))

    def test_a_final_message_under_the_minimum_age_is_running(self):
        self.assertEqual(self.check([entry("assistant", TEXT, 10)]), (1, "RUNNING 10s"))

    def test_the_minimum_age_is_30_seconds_and_an_option(self):
        self.assertEqual(self.check([entry("assistant", TEXT, 30)])[0], 0)
        self.assertEqual(self.check([entry("assistant", TEXT, 29)])[0], 1)
        self.assertEqual(self.check([entry("assistant", TEXT, 29)], "--min-age", "5")[0], 0)

    def test_a_pending_tool_call_is_running_however_old(self):
        self.assertEqual(self.check([entry("assistant", TEXT, 900), entry("assistant", TOOL, 600)]), (1, "RUNNING 600s"))

    def test_a_tool_result_after_the_last_message_is_running(self):
        lines = [entry("assistant", TOOL, 900), entry("user", RESULT, 800)]
        self.assertEqual(self.check(lines), (1, "RUNNING 800s"))

    def test_a_message_split_into_a_text_entry_and_a_tool_entry_is_running(self):
        self.assertEqual(self.check([entry("assistant", TEXT, 200), entry("assistant", TOOL, 199)])[0], 1)

    def test_a_final_message_after_earlier_tool_calls_has_ended(self):
        lines = [entry("assistant", TOOL, 900), entry("user", RESULT, 800), entry("assistant", TEXT, 700)]
        self.assertEqual(self.check(lines), (0, "ENDED"))

    def test_a_message_sent_to_a_stopped_agent_makes_it_running_again(self):
        self.assertEqual(self.check([entry("assistant", TEXT, 500), entry("user", "go on", 400)]), (1, "RUNNING 400s"))

    def test_entries_of_other_types_move_the_age_but_not_the_verdict(self):
        self.assertEqual(self.check([entry("assistant", TEXT, 300), other("attachment", 100)]), (0, "ENDED"))
        self.assertEqual(self.check([entry("assistant", TEXT, 300), other("attachment", 5)]), (1, "RUNNING 5s"))

    def test_a_subagent_handback_and_its_result_have_ended(self):
        handback = [{"type": "tool_use", "id": "h1", "name": "SubagentHandback", "input": {"message": "report"}}]
        answer = [{"type": "tool_result", "tool_use_id": "h1", "content": "ok"}]
        lines = [entry("assistant", TOOL, 900), entry("user", RESULT, 800), entry("assistant", handback, 300)]
        self.assertEqual(self.check(lines), (0, "ENDED"))
        lines += [other("api-request", 290), entry("user", answer, 280), other("api-request-blob", 270)]
        self.assertEqual(self.check(lines), (0, "ENDED"))
        self.assertEqual(self.check(lines + [entry("user", "go on", 100)]), (1, "RUNNING 100s"))

    def test_a_handback_beside_another_call_or_answered_by_another_result_is_running(self):
        handback = [{"type": "tool_use", "id": "h1", "name": "SubagentHandback", "input": {}}]
        self.assertEqual(self.check([entry("assistant", handback + TOOL, 300)]), (1, "RUNNING 300s"))
        lines = [entry("assistant", handback, 300), entry("user", RESULT, 290)]
        self.assertEqual(self.check(lines), (1, "RUNNING 290s"))

    def test_blank_and_broken_lines_are_skipped(self):
        self.assertEqual(self.check(["", "{not json", "[1, 2]", entry("assistant", TEXT, 100)]), (0, "ENDED"))

    def test_an_empty_transcript_is_running(self):
        self.assertEqual(self.check([])[0], 1)

    def test_a_missing_transcript_exits_2(self):
        err = io.StringIO()
        with redirect_stderr(err):
            code = module.main([str(self.dir / "none.jsonl")], now=NOW)
        self.assertEqual(code, 2)
        self.assertIn("cannot read the transcript", err.getvalue())

    def lsof_text(self, *rows):
        return "".join("p%d\nc%s\nfcwd\nn%s\n" % row for row in rows)

    def worktree(self):
        wt = self.dir / "wt"
        (wt / "Sources").mkdir(parents=True, exist_ok=True)
        return wt

    def test_a_process_in_the_worktree_keeps_a_finished_agent_running(self):
        wt = self.worktree()
        text = self.lsof_text((77, "zsh", self.dir), (4242, "swift-build", wt / "Sources"))
        code, out = self.check([entry("assistant", TEXT, 120)], "--worktree", str(wt), lsof=lambda: text)
        self.assertEqual((code, out), (1, "RUNNING 120s busy in the worktree: swift-build 4242"))

    def test_the_worktree_itself_counts_as_a_working_folder(self):
        wt = self.worktree()
        code, out = self.check([entry("assistant", TEXT, 120)], "--worktree", str(wt), lsof=lambda: self.lsof_text((5, "xctest", wt)))
        self.assertEqual(code, 1)

    def test_processes_elsewhere_do_not_count(self):
        wt = self.worktree()
        sibling = self.dir / "wt2"
        sibling.mkdir()
        text = self.lsof_text((1, "launchd", "/"), (2, "zsh", self.dir), (3, "swift-build", sibling), (os.getpid(), "me", wt))
        self.assertEqual(self.check([entry("assistant", TEXT, 120)], "--worktree", str(wt), lsof=lambda: text), (0, "ENDED"))

    def test_a_failed_lsof_does_not_confirm_the_end(self):
        wt = self.worktree()
        code, out = self.check([entry("assistant", TEXT, 120)], "--worktree", str(wt), lsof=lambda: None)
        self.assertEqual((code, out), (1, "RUNNING 120s lsof failed, so the worktree is not confirmed idle"))

    def test_lsof_is_not_run_without_a_worktree(self):
        def never():
            raise AssertionError("lsof must not run")
        self.assertEqual(self.check([entry("assistant", TEXT, 120)], lsof=never), (0, "ENDED"))

    def test_parse_lsof_reads_the_field_output(self):
        procs = module.parse_lsof("p12\nczsh\nfcwd\nn/a/b\np13\ncxctest\nfcwd\nn/c d\n\nxjunk\n")
        self.assertEqual(procs, [{"pid": 12, "command": "zsh", "cwd": "/a/b"}, {"pid": 13, "command": "xctest", "cwd": "/c d"}])

    def test_the_script_ends_no_process(self):
        text = SCRIPT.read_text()
        for word in ("os.kill", "pkill", "killall", ".terminate(", ".kill("):
            self.assertNotIn(word, text)


if __name__ == "__main__":
    unittest.main()
