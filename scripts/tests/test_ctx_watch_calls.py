"""Tests for the call check of scripts/session/ctx_watch.py (--calls) and its use in scripts/session/heartbeat.sh.

Each test writes a small synthetic session in a temporary folder (subagent transcripts, meta files and agent type files)
and checks the lines the scripts print. The heartbeat runs one round with no sleep.
"""
import contextlib
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).parents[1]
SCRIPT, HEARTBEAT = SCRIPTS / 'session' / 'ctx_watch.py', SCRIPTS / 'session' / 'heartbeat.sh'
LEDGER, REPO_TYPES = SCRIPTS / 'llm' / 'session_ledger.py', Path(__file__).parents[2] / '.claude' / 'agents'
SID = '11111111-2222-3333-4444-555555555555'
A, B, C, D = ('%s0123456789abcdef' % c for c in 'abcd')
START = datetime(2026, 11, 14, 8, 0, tzinfo=timezone.utc)
FAKE_DF = '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/fake 99 1 $FAKE_DF_KB 1% /"\n'


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def transcript(prompt, calls, when, final, tokens):
    """The entries of one agent. Its prompt, CALLS tool calls each answered by a result, then a closing message if FINAL."""
    usage = {'input_tokens': 10, 'cache_read_input_tokens': tokens, 'cache_creation_input_tokens': 0}

    def entry(kind, n, content):
        message = {'role': kind, 'content': content}
        if kind == 'assistant':
            message.update(id='m%d' % n, usage=usage)
        stamp = (when + timedelta(seconds=n)).strftime('%Y-%m-%dT%H:%M:%S.000Z')
        return {'type': kind, 'uuid': 'e%d' % n, 'timestamp': stamp, 'message': message}

    out = [entry('user', 0, prompt)]
    for n in range(1, calls + 1):
        use = {'type': 'tool_use', 'id': 't%d' % n, 'name': 'Bash', 'input': {}}
        out.append(entry('assistant', 2 * n - 1, [use]))
        out.append(entry('user', 2 * n, [{'type': 'tool_result', 'tool_use_id': 't%d' % n, 'content': 'ok'}]))
    if final:
        out.append(entry('assistant', 2 * calls + 1, [{'type': 'text', 'text': 'Done.'}]))
    return out


class Session:
    """A temporary project folder with one session, its subagents and a folder of agent type files."""

    def __init__(self, test, when=START):
        tmp = tempfile.TemporaryDirectory()
        test.addCleanup(tmp.cleanup)
        self.root, self.when = Path(tmp.name), when
        self.project, self.types = self.root / 'project', self.root / 'agents'
        self.sub = self.project / SID / 'subagents'
        self.sub.mkdir(parents=True)
        self.types.mkdir()

    def agent(self, aid, prompt, calls, kind=None, final=False, tokens=10_000):
        entries = transcript(prompt, calls, self.when, final, tokens)
        (self.sub / ('agent-%s.jsonl' % aid)).write_text(''.join(json.dumps(e) + '\n' for e in entries))
        meta = {'description': 'lane ' + aid[:1], **({'agentType': kind} if kind else {})}
        (self.sub / ('agent-%s.meta.json' % aid)).write_text(json.dumps(meta))

    def type_file(self, name, body, front=''):
        (self.types / (name + '.md')).write_text('---\nname: %s\n%smodel: sonnet\n---\n\n%s\n' % (name, front, body))


class CallsTests(unittest.TestCase):
    def setUp(self):
        self.module, self.session = load(SCRIPT, 'ctx_watch'), Session(self)

    def check(self, *args):
        """The lines of ctx_watch --calls over the session, reading type files from the session's folder."""
        out, err = io.StringIO(), io.StringIO()
        argv = [str(self.session.project), SID, '--calls', '--agents-dir', str(self.session.types), *args]
        with contextlib.redirect_stderr(err):
            try:
                code = self.module.main(argv, now=START.timestamp() + 1000, out=out)
            except SystemExit as stop:
                code = stop.code
        self.assertEqual(code, 0, err.getvalue())
        return out.getvalue().splitlines()

    def test_a_line_in_the_prompt_in_each_form(self):
        forms = ['Stop at 4 calls.', 'stop at call 4', 'Stop at about 4 tool calls. Report to a file.',
                 'Write your Handoff and stop by about 4 tool calls, or at once if blocked.', 'Stop line 4 calls.',
                 'STOP AT 4 CALLS', 'The lane stops at 4 calls.']
        for form in forms:
            with self.subTest(form):
                self.session.agent(A, 'Lane X. ' + form, 3)
                self.assertEqual(self.check(), ['none'])
                self.session.agent(A, 'Lane X. ' + form, 4)
                self.assertEqual(self.check(), ['CALLS %s 4/4' % A])

    def test_the_first_form_in_the_prompt_sets_the_line_and_calls_past_it_are_shown(self):
        self.session.agent(A, 'Stop at about 6 tool calls, and later stop at call 3.', 4)
        self.session.agent(B, 'Stop at call 3. Stop line 6 calls.', 7)
        self.assertEqual(self.check(), ['CALLS %s 7/3' % B])

    def test_wording_that_is_no_stop_line_is_ignored(self):
        for prompt in ('Keep to 2 calls.', 'Handoff at 2 calls.', 'Stop at 2.', 'Stop at 2 files.', 'At most 2 calls.',
                       'Stop at 1.5 times the calls your prompt estimates.'):
            with self.subTest(prompt):
                self.session.agent(A, prompt, 9)
                self.assertEqual(self.check(), ['none'])

    def test_a_prompt_without_a_form_takes_the_line_of_its_type_file_and_a_prompt_line_wins(self):
        self.session.type_file('lge-lane', 'Write your Handoff at 2 calls and stop at 5 calls or 300K of context.')
        self.session.agent(A, 'No line here.', 5, 'lge-lane')
        self.session.agent(B, 'No line here.', 4, 'lge-lane')
        self.session.agent(C, 'Stop at about 3 calls.', 3, 'lge-lane')
        self.assertEqual(self.check(), ['CALLS %s 5/5' % A, 'CALLS %s 3/3' % C])

    def test_agents_with_no_line_and_agents_that_ended_are_not_listed(self):
        self.session.type_file('lge-bare', 'Nothing about calls.')
        self.session.type_file('lge-fix', 'Stop at 1.5 times the calls your prompt estimates, and at 2 calls when it gives none.')
        for aid, kind in ((A, None), (B, 'lge-bare'), (C, 'general-purpose'), (D, 'lge-fix')):
            self.session.agent(aid, 'No line.', 9, kind)
        self.session.agent('e0123456789abcdef', 'Stop at 3 calls.', 5, final=True)
        self.assertEqual(self.check(), ['none'])

    def test_a_prompt_in_blocks_is_read_and_a_type_name_that_leaves_the_folder_is_not(self):
        self.session.agent(A, [{'type': 'text', 'text': 'Lane Y.'}, {'type': 'text', 'text': 'Stop at 2 calls.'}], 2)
        (self.session.root / 'outside.md').write_text('Stop at 1 calls.\n')
        self.session.agent(B, 'No line.', 5, '../outside')
        self.assertEqual(self.check(), ['CALLS %s 2/2' % A])

    def test_other_filters_apply_and_no_message_text_is_printed(self):
        self.session.agent(A, 'SECRET WORDS. Stop at 2 calls.', 2, tokens=100_000)
        self.session.agent(B, 'SECRET WORDS. Stop at 2 calls.', 2, tokens=350_000)
        self.assertEqual(self.check(), ['CALLS %s 2/2' % A, 'CALLS %s 2/2' % B])
        self.assertEqual(self.check('--over', '300'), ['CALLS %s 2/2' % B])
        self.assertEqual(self.check('--over', '900'), ['none'])


class TypeLineTests(unittest.TestCase):
    CASES = [
        ('Write your Handoff at 75 calls and stop at 85 calls or 300K of context. Docs work stops at 60.', 85),
        ('The stop line is 150 calls over Part A and Part B. Stop at the first commit past the line.', 150),
        ('Write your file by call 50 and stop at 70, and at the line give the verdict.', 70),
        ('Stop at 1.5 times the calls your prompt estimates, and at 60 calls when it gives none.', None),
        ('Stop only a process you started, by PID. Stop at 300K of context. Stop and report.', None),
    ]

    def test_the_line_a_type_file_names_and_the_front_matter_it_skips(self):
        module, session = load(SCRIPT, 'ctx_watch'), Session(self)

        def line(name):
            return module.type_stop_line(name, str(session.types))

        for body, expected in self.CASES:
            with self.subTest(body):
                session.type_file('lge-x', body)
                self.assertEqual(line('lge-x'), expected)
        session.type_file('lge-x', 'Stop at 12 calls.', front='description: Stop at 9 calls.\n')
        session.type_file('lge-y', 'Nothing here.', front='description: Stop at 9 calls.\n')
        self.assertEqual((line('lge-x'), line('lge-y'), line('lge-missing'), line(None)), (12, None, None, None))

    def test_each_repository_type_that_names_a_stop_line_gives_a_whole_number(self):
        module = load(SCRIPT, 'ctx_watch')
        for name in ('lge-lane', 'lge-lane-opus', 'lge-review', 'lge-ruling', 'lge-land', 'lge-planner', 'lge-release',
                     'lge-walker', 'lge-expert', 'llm-efficiency-monitor'):
            with self.subTest(name):
                line = module.type_stop_line(name, str(REPO_TYPES))
                self.assertTrue(isinstance(line, int) and line > 0, line)

    def test_the_default_folder_is_the_one_the_ledger_reads(self):
        folder = Path(load(SCRIPT, 'ctx_watch').default_agents_dir()).resolve()
        self.assertEqual(folder, Path(load(LEDGER, 'session_ledger').AGENTS_DIR).resolve())
        self.assertEqual(folder, REPO_TYPES.resolve())


class HeartbeatCallsTests(unittest.TestCase):
    def setUp(self):
        self.session = Session(self, datetime.now(timezone.utc) - timedelta(minutes=5))
        self.records, self.bin = self.session.root / 'records', self.session.root / 'bin'
        self.records.mkdir()
        self.bin.mkdir()
        (self.bin / 'df').write_text(FAKE_DF)
        (self.bin / 'df').chmod(0o755)

    def beat(self, *extra):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'], PYTHON=sys.executable,
                   FAKE_DF_KB=str(500 * 1048576))
        command = ['bash', str(HEARTBEAT), '--project', str(self.session.project), '--session', SID, '--records',
                   str(self.records), '--interval', '0', '--rounds', '1', '--no-memwatch', *extra]
        done = subprocess.run(command, capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout

    def test_an_agent_at_its_prompt_line_ends_the_round_and_one_below_it_does_not(self):
        self.session.agent(A, 'Stop at 3 calls.', 2)
        self.assertTrue(self.beat().startswith('QUIET '))
        self.session.agent(A, 'Stop at 3 calls.', 3)
        lines = self.beat().splitlines()
        self.assertEqual((lines[0][:6], lines[1:]), ('ALARM ', ['CALLS %s 3/3' % A]))

    def test_the_line_of_the_type_file_is_read_when_the_prompt_has_none(self):
        line = load(SCRIPT, 'ctx_watch').type_stop_line('lge-ruling', str(REPO_TYPES))
        self.session.agent(A, 'No line here.', line - 1, 'lge-ruling')
        self.assertTrue(self.beat().startswith('QUIET '))
        self.session.agent(A, 'No line here.', line, 'lge-ruling')
        self.assertIn('CALLS %s %d/%d' % (A, line, line), self.beat())

    def test_ended_agents_listed_ids_and_agents_with_no_line_are_ignored(self):
        self.session.agent(A, 'Stop at 2 calls.', 4, final=True)
        self.session.agent(B, 'Stop at 2 calls.', 4)
        self.session.agent(C, 'No line here.', 60)
        (self.records / 'done_ids.txt').write_text(B + '\n')
        self.assertTrue(self.beat().startswith('QUIET '))

    def test_the_wait_ends_at_the_first_round_with_a_finding(self):
        self.session.agent(A, 'Stop at 2 calls.', 2)
        out = self.beat('--rounds', '3')
        self.assertEqual((out.count('ALARM'), 'QUIET' in out), (1, False))

    def test_the_script_has_no_syntax_error(self):
        self.assertEqual(subprocess.run(['bash', '-n', str(HEARTBEAT)], capture_output=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
