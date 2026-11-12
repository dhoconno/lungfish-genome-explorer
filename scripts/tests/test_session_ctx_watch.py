"""Tests for scripts/session/ctx_watch.py, the context and pending-call reader for the agents of a session.

Each test writes a small synthetic session in a temporary folder (subagent transcripts and their meta files) and
checks the lines that ctx_watch prints. No real transcript is read.
"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone

SCRIPT = Path(__file__).parents[1] / 'session' / 'ctx_watch.py'
SID = '11111111-2222-3333-4444-555555555555'
T0 = datetime(2026, 11, 12, 10, 0, tzinfo=timezone.utc).timestamp()
A, B, C = 'a0123456789abcdef', 'b0123456789abcdef', 'c0123456789abcdef'


def load():
    spec = importlib.util.spec_from_file_location('ctx_watch', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stamp(seconds):
    return datetime.fromtimestamp(T0 + seconds, timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')


def assistant(n, seconds, mid, tokens=0, tool=None, text=None):
    content = [{'type': 'text', 'text': text}] if text else []
    if tool:
        content.append({'type': 'tool_use', 'id': tool, 'name': 'Bash', 'input': {}})
    usage = {'input_tokens': 10, 'cache_read_input_tokens': tokens, 'cache_creation_input_tokens': 0}
    return {'type': 'assistant', 'uuid': 'u%d' % n, 'timestamp': stamp(seconds),
            'message': {'id': mid, 'content': content, 'usage': usage}}


def user(n, seconds):
    return {'type': 'user', 'uuid': 'u%d' % n, 'timestamp': stamp(seconds),
            'message': {'role': 'user', 'content': [{'type': 'tool_result', 'content': 'ok'}]}}


class CtxWatchTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.project = tmp.name
        self.sub = Path(tmp.name) / SID / 'subagents'
        self.sub.mkdir(parents=True)
        self.module = load()

    def agent(self, aid, entries, desc=None):
        (self.sub / ('agent-%s.jsonl' % aid)).write_text(''.join(json.dumps(e) + '\n' for e in entries))
        if desc is not None:
            (self.sub / ('agent-%s.meta.json' % aid)).write_text(json.dumps({'description': desc}))

    def busy(self, aid, tokens, last=10, desc='lane'):
        self.agent(aid, [user(1, 0), assistant(2, last, 'm-' + aid, tokens, tool='t-' + aid)], desc)

    def final(self, aid, tokens, last=10):
        self.agent(aid, [user(1, 0), assistant(2, last, 'm-' + aid, tokens, text='Done.')], 'finished lane')

    def watch(self, *args, now=T0 + 1000):
        out = io.StringIO()
        code = self.module.main([self.project, SID, *args], now=now, out=out)
        return code, out.getvalue()

    def ids(self, *args):
        return [line[:17] for line in self.watch(*args)[1].splitlines()]

    def test_busy_line_shows_calls_context_age_and_state(self):
        self.busy(A, 271_000, last=10, desc='SESSION-SCRIPTS-B lane')
        code, text = self.watch(now=T0 + 130)
        self.assertEqual(code, 0)
        self.assertIn(A + ' SESSION-SCRIPTS-B lane', text)
        self.assertIn('calls   1 ctx  271K age   120s busy', text)
        self.assertNotIn('STOP', text)

    def test_context_is_the_last_turn_not_a_sum(self):
        self.agent(A, [user(1, 0), assistant(2, 5, 'm1', 100_000, tool='t1'), user(3, 6),
                       assistant(4, 9, 'm2', 250_000, tool='t2')])
        self.assertIn('calls   2 ctx  250K', self.watch()[1])

    def test_final_state_and_stop_flags(self):
        self.final(A, 310_000)
        self.busy(B, 410_000)
        self.busy(C, 290_000)
        lines = {line[:17]: line.split() for line in self.watch()[1].splitlines()}
        self.assertEqual(lines[A][-2:], ['final', 'REVIEW-STOP'])
        self.assertEqual(lines[B][-2:], ['busy', 'SEND-STOP'])
        self.assertEqual(lines[C][-1], 'busy')

    def test_stop_lines_are_arguments(self):
        self.busy(A, 290_000)
        self.busy(B, 310_000)
        text = self.watch('--review-k', '250', '--send-k', '300')[1]
        lines = {line[:17]: line.split() for line in text.splitlines()}
        self.assertEqual(lines[A][-1], 'REVIEW-STOP')
        self.assertEqual(lines[B][-1], 'SEND-STOP')

    def test_over_and_busy_filters(self):
        self.busy(A, 100_000)
        self.busy(B, 320_000)
        self.final(C, 350_000)
        self.assertEqual(self.ids('--over', '300'), [B, C])
        self.assertEqual(self.ids('--over', '300', '--busy'), [B])
        self.assertEqual(self.watch('--over', '900')[1], 'none\n')

    def test_stalled_keeps_old_busy_agents_only(self):
        self.busy(A, 50_000, last=10)
        self.busy(B, 50_000, last=500)
        self.final(C, 50_000, last=10)
        lines = self.watch('--stalled', '900')[1].splitlines()
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith('STALLED ' +A))
        self.assertIn('age   990s', lines[0])
        self.assertEqual(self.watch('--stalled', '2000')[1], 'none\n')

    def test_filters_given_together_must_all_pass(self):
        self.busy(A, 50_000)
        self.busy(B, 350_000)
        lines = self.watch('--stalled', '900', '--over', '300')[1].splitlines()
        self.assertEqual([line[:25] for line in lines], ['STALLED ' +B])

    def test_one_turn_split_over_entries_counts_once(self):
        thinking = assistant(2, 5, 'm1', 200_000)
        call = assistant(3, 6, 'm1', 200_000, tool='t1')
        self.agent(A, [user(1, 0), thinking, call, call], 'split turn')
        text = self.watch()[1]
        self.assertIn('calls   1 ctx  200K', text)
        self.assertIn('busy', text)

    def test_session_without_subagents_prints_none(self):
        (Path(self.project) / 'quiet-session').mkdir()
        (Path(self.project) / 'solo-session.jsonl').write_text('')
        for sid in ('quiet-session', 'solo-session'):
            out = io.StringIO()
            self.assertEqual(self.module.main([self.project, sid], now=T0, out=out), 0)
            self.assertEqual(out.getvalue(), 'none\n')

    def test_unknown_session_exits_2(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stderr(err):
            code = self.module.main([self.project, 'no-such-session'], now=T0, out=out)
        self.assertEqual((code, out.getvalue()), (2, ''))
        self.assertIn('no-such-session', err.getvalue())

    def test_bad_lines_are_skipped_and_message_text_is_never_printed(self):
        good = assistant(2, 10, 'm1', 20_000, text='SECRET WORDS')
        lines = ['not json', '[1, 2]', '', json.dumps(user(1, 0)), json.dumps(good),
                 '{"type": "assistant", "message": 5}']
        (self.sub / ('agent-%s.jsonl' % A)).write_text('\n'.join(lines) + '\n')
        text = self.watch()[1]
        self.assertIn('ctx   20K', text)
        self.assertNotIn('SECRET', text)

    def test_description_is_cut_at_34_characters(self):
        self.busy(A, 1000, desc='x' * 50)
        text = self.watch()[1]
        self.assertIn(A + ' ' + 'x' * 34 + ' calls', text)
        self.assertNotIn('x' * 35, text)

    def test_script_runs_from_the_command_line(self):
        self.busy(A, 50_000)
        done = subprocess.run([sys.executable, str(SCRIPT), self.project, SID], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0)
        self.assertTrue(done.stdout.startswith(A))

    def test_source_names_no_process_killers(self):
        source = SCRIPT.read_text()
        for banned in ('pk' + 'ill', 'kill' + 'all', 'os.kill'):
            self.assertNotIn(banned, source)


if __name__ == '__main__':
    unittest.main()
