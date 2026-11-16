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
from unittest import mock

SCRIPTS = Path(__file__).parents[1]
SCRIPT, HEARTBEAT = SCRIPTS / 'session' / 'ctx_watch.py', SCRIPTS / 'session' / 'heartbeat.sh'
LEDGER, REPO_TYPES = SCRIPTS / 'llm' / 'session_ledger.py', Path(__file__).parents[2] / '.claude' / 'agents'
SID = '11111111-2222-3333-4444-555555555555'
A, B, C, D = ('%s0123456789abcdef' % c for c in 'abcd')
START = datetime(2026, 11, 14, 8, 0, tzinfo=timezone.utc)
FAKE_DF = '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/fake 99 1 $FAKE_DF_KB 1% /"\n'
# A sleep that returns at once. It logs its argument, and after its Nth call copies the file SLEEP_SWAP/N over SLEEP_TARGET,
# so a test can move an agent's transcript on while the heartbeat waits.
FAKE_SLEEP = ('#!/bin/sh\necho "$1" >> "$SLEEP_LOG"\nn=$(wc -l < "$SLEEP_LOG" | tr -d " ")\n'
              'if [ -f "$SLEEP_SWAP/$n" ]; then cp "$SLEEP_SWAP/$n" "$SLEEP_TARGET"; fi\n')


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

    def brief(self, text, name='brief.md'):
        """The path, as a string, of a brief file with this text in the session's temporary folder."""
        (self.session.root / name).write_text(text)
        return str(self.session.root / name)

    def test_a_prompt_with_no_line_takes_the_line_of_the_brief_it_names_in_each_form(self):
        names = ['Your brief is %s.', 'Lane X, brief file %s', 'Brief: %s', 'Brief %s, order and shared files in w.md.',
                 'Do the items under the brief `%s`.', 'The brief is "%s".']
        briefs = ['Stop at 4 tool calls.', 'Stop by your 4th tool call: write a Handoff and end.',
                  'Rules.\n\n- Stop at call 4. Report to a file.\n']
        for name in names:
            for text in briefs:
                with self.subTest(name, brief=text):
                    prompt = name % self.brief(text)
                    self.session.agent(A, prompt, 3)
                    self.assertEqual(self.check(), ['none'])
                    self.session.agent(A, prompt, 4)
                    self.assertEqual(self.check(), ['CALLS %s 4/4' % A])

    def test_the_prompt_line_wins_over_the_brief_and_the_brief_over_the_type_file(self):
        self.session.type_file('lge-lane', 'Stop at 9 calls.')
        five = self.brief('Stop at 5 tool calls.')
        bare = self.brief('Keep to 2 calls. Handoff at 2 calls. Stop at 2 files. Stop at 1.5 times the calls.', 'bare.md')
        self.session.agent(A, 'Stop at 3 tool calls. Your brief is %s.' % five, 3, 'lge-lane')
        self.session.agent(B, 'Your brief is %s.' % five, 5, 'lge-lane')
        self.session.agent(C, 'Your brief is %s.' % bare, 9, 'lge-lane')
        self.session.agent(D, 'Your brief is %s.' % bare, 8, 'lge-lane')
        self.assertEqual(self.check(), ['CALLS %s 3/3' % A, 'CALLS %s 5/5' % B, 'CALLS %s 9/9' % C])

    def test_a_brief_that_is_missing_a_folder_or_a_relative_path_leaves_the_type_line(self):
        self.session.type_file('lge-lane', 'Stop at 2 calls.')
        (self.session.root / 'folder.md').mkdir()
        root = self.session.root
        for prompt in ('Your brief is %s/missing.md.' % root, 'Your brief is %s/folder.md.' % root,
                       'Your brief is briefs/relative.md.', 'Your brief is the file in the records folder.'):
            with self.subTest(prompt):
                self.session.agent(A, prompt, 2, 'lge-lane')
                self.assertEqual(self.check(), ['CALLS %s 2/2' % A])

    def test_the_first_brief_that_can_be_read_is_used_and_a_path_may_start_at_home(self):
        late = self.brief('Stop at 3 calls.', 'late.md')
        self.session.agent(A, 'Brief %s/missing.md, then the brief %s.' % (self.session.root, late), 3)
        self.session.agent(B, 'Your brief is ~/late.md.', 3)
        with mock.patch.dict(os.environ, {'HOME': str(self.session.root)}):
            self.assertEqual(self.check(), ['CALLS %s 3/3' % A, 'CALLS %s 3/3' % B])

    def test_a_line_in_the_form_stop_by_your_nth_tool_call_is_read_as_its_number(self):
        for text, expected in (('Stop by your 1st tool call.', 1), ('Stop by your 22nd tool call', 22),
                               ('Lane X. Stop by the 103rd call, then write a Handoff.', 103),
                               ('STOP BY YOUR 120TH TOOL CALL: write what you have.', 120),
                               ('Stop by your last tool call.', None), ('Stop by your 2nd file.', None)):
            with self.subTest(text):
                self.assertEqual(self.module.prompt_stop_line(text), expected)

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

    def test_a_parallel_batch_counts_each_call_as_the_ledger_does(self):
        def use(tid):
            return {'type': 'tool_use', 'id': tid, 'name': 'Bash', 'input': {}}

        def result(tid):
            return [{'type': 'tool_result', 'tool_use_id': tid, 'content': 'ok'}]

        script = [('user', 'Stop at 5 calls.', None), ('assistant', [use('a1'), use('a2')], 'm1'),
                  ('user', result('a1') + result('a2'), None), ('assistant', [use('b1')], 'm2'),
                  ('user', result('b1'), None), ('assistant', [use('b2')], 'm2'), ('user', result('b2'), None),
                  ('assistant', [use('b3')], 'm2')]
        usage = {'input_tokens': 10, 'cache_read_input_tokens': 10_000, 'cache_creation_input_tokens': 0}
        entries = []
        for n, (kind, content, mid) in enumerate(script):
            message = {'role': kind, 'content': content, **({'id': mid, 'usage': usage} if mid else {})}
            stamp = (START + timedelta(seconds=n)).strftime('%Y-%m-%dT%H:%M:%S.000Z')
            entries.append({'type': kind, 'uuid': 'e%d' % n, 'timestamp': stamp, 'message': message})
        path = self.session.sub / ('agent-%s.jsonl' % A)
        path.write_text(''.join(json.dumps(e) + '\n' for e in entries))
        agents = {}
        load(LEDGER, 'session_ledger').load_file(str(path), agents, A, 'sub', SID)
        self.assertEqual(sum(sum(agent.tool_names.values()) for agent in agents.values()), 5)
        self.assertEqual(self.check(), ['CALLS %s 5/5' % A])


    def test_near_adds_a_line_for_each_running_agent_within_n_calls_below_its_line(self):
        for aid, calls in ((A, 4), (B, 5), (C, 19), (D, 20)):
            self.session.agent(aid, 'Stop at 20 calls.', calls)
        self.session.agent('e0123456789abcdef', 'Stop at 20 calls.', 12, final=True)
        self.session.agent('f0123456789abcdef', 'No line here.', 19)
        self.assertEqual(self.check(), ['CALLS %s 20/20' % D])
        self.assertEqual(self.check('--near', '15'), ['NEAR %s 5/20' % B, 'NEAR %s 19/20' % C, 'CALLS %s 20/20' % D])
        self.assertEqual(self.check('--near', '0'), ['CALLS %s 20/20' % D])


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

    def test_the_line_each_repository_type_names_is_the_number_of_its_stop_sentence(self):
        module = load(SCRIPT, 'ctx_watch')
        lines = {'lge-lane': 85, 'lge-lane-opus': 130, 'lge-review': 100, 'lge-ruling': 40, 'lge-land': 150,
                 'lge-planner': 80, 'lge-release': 100, 'lge-walker': 45, 'lge-expert': 60,
                 'llm-efficiency-monitor': 80, 'lge-fix': 60}
        for name, expected in lines.items():
            with self.subTest(name):
                self.assertEqual(module.type_stop_line(name, str(REPO_TYPES)), expected)

    def test_every_lge_type_and_the_monitor_names_a_stop_line(self):
        """Seven other type files (the writing and reading helpers) name no line and stay out. A type with no line cannot alarm."""
        module = load(SCRIPT, 'ctx_watch')
        names = sorted(path.stem for path in REPO_TYPES.glob('lge-*.md')) + ['llm-efficiency-monitor']
        self.assertIn('lge-fix', names)
        for name in names:
            with self.subTest(name):
                line = module.type_stop_line(name, str(REPO_TYPES))
                self.assertIsInstance(line, int, '%s.md names no stop line' % name)
                self.assertGreater(line, 0)

    def test_no_type_sets_its_line_from_an_estimate_the_watcher_cannot_read(self):
        """lge-fix stopped at 1.5 times an estimate while ctx_watch read its 60, so two fix agents alarmed at 60/60 under
        lines of 67 (O177 ballot 3 Q4). A line other than the type's goes in the prompt as "Stop at N tool calls."."""
        for path in sorted(REPO_TYPES.glob('lge-*.md')):
            with self.subTest(path.stem):
                self.assertNotRegex(path.read_text(), r'(?i)\bestimates?\b')

    def test_the_default_folder_is_the_one_the_ledger_reads(self):
        folder = Path(load(SCRIPT, 'ctx_watch').default_agents_dir()).resolve()
        self.assertEqual(folder, Path(load(LEDGER, 'session_ledger').AGENTS_DIR).resolve())
        self.assertEqual(folder, REPO_TYPES.resolve())


class HeartbeatCallsTests(unittest.TestCase):
    def setUp(self):
        self.session = Session(self, datetime.now(timezone.utc) - timedelta(minutes=5))
        self.records, self.bin = self.session.root / 'records', self.session.root / 'bin'
        self.swap, self.sleeps = self.session.root / 'swap', self.session.root / 'sleeps.log'
        for folder in (self.records, self.bin, self.swap):
            folder.mkdir()
        for name, text in (('df', FAKE_DF), ('sleep', FAKE_SLEEP)):
            (self.bin / name).write_text(text)
            (self.bin / name).chmod(0o755)

    def slept(self):
        """The seconds each wait of the last beat asked for."""
        return self.sleeps.read_text().split()

    def beat(self, *extra):
        self.sleeps.write_text('')
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'], PYTHON=sys.executable,
                   FAKE_DF_KB=str(500 * 1048576), SLEEP_LOG=str(self.sleeps), SLEEP_SWAP=str(self.swap),
                   SLEEP_TARGET=str(self.session.sub / ('agent-%s.jsonl' % A)))
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

    def test_a_blank_line_or_a_note_in_done_ids_hides_no_line_of_another_agent(self):
        """A blank line made an empty alternative in the filter, which matched every context, STALLED and CALLS line."""
        self.session.agent(A, 'Stop at 2 calls.', 4)
        self.session.agent(B, 'No line here.', 2, tokens=350_000)
        self.session.agent(C, 'Stop at 2 calls.', 4, tokens=350_000)
        (self.records / 'done_ids.txt').write_text(C + '\n\n# a note\n')
        lines = self.beat('--pending-s', '100').splitlines()
        self.assertEqual(lines[0][:6], 'ALARM ', lines)
        self.assertIn('CALLS %s 4/2' % A, lines)
        self.assertEqual(sorted(line.split()[1] for line in lines if line.startswith('STALLED')), [A, B])
        self.assertEqual([line.split()[0] for line in lines if line.startswith(B)], [B])
        self.assertEqual([line for line in lines if C in line], [])

    def test_the_wait_ends_at_the_first_round_with_a_finding(self):
        self.session.agent(A, 'Stop at 2 calls.', 2)
        out = self.beat('--rounds', '3')
        self.assertEqual((out.count('ALARM'), 'QUIET' in out), (1, False))

    def test_an_id_in_stop_sent_is_not_alarmed_for_its_calls_and_blank_lines_and_notes_name_nobody(self):
        self.session.agent(A, 'Stop at 2 calls.', 4)
        self.session.agent(B, 'Stop at 2 calls.', 4)
        (self.records / 'stop_sent.txt').write_text('\n# sent 07:22\n' + A + '\n\n')
        lines = self.beat().splitlines()
        self.assertEqual((lines[0][:6], lines[1:]), ('ALARM ', ['CALLS %s 4/2' % B]))
        (self.records / 'stop_sent.txt').write_text(A + '\n' + B + '\n')
        self.assertTrue(self.beat().startswith('QUIET '))

    def test_a_short_id_in_stop_sent_names_the_agents_whose_ids_start_with_it(self):
        self.session.agent(A, 'Stop at 2 calls.', 4)
        (self.records / 'stop_sent.txt').write_text(A[:8] + '\n')
        self.assertTrue(self.beat().startswith('QUIET '))

    def test_stop_sent_leaves_the_context_line_alone(self):
        self.session.agent(A, 'Stop at 2 calls.', 4, tokens=350_000)
        (self.records / 'stop_sent.txt').write_text(A + '\n')
        out = self.beat()
        self.assertEqual((out[:6], A in out, 'CALLS' in out), ('ALARM ', True, False))

    def test_the_first_look_comes_before_any_wait_and_a_quiet_run_waits_once_for_each_round(self):
        self.session.agent(A, 'Stop at 3 calls.', 3)
        out = self.beat('--interval', '3600')
        self.assertEqual((out.splitlines()[1:], self.slept()), (['CALLS %s 3/3' % A], []))
        self.session.agent(A, 'Stop at 80 calls.', 2)
        self.assertEqual((self.beat('--interval', '300', '--rounds', '3')[:6], self.slept()), ('QUIET ', ['300'] * 3))

    def test_an_agent_within_seventy_five_calls_of_its_line_is_checked_every_minute(self):
        """At 12.7 to 14.9 calls a minute an agent covers about 75 calls in one 5-minute wait (O177 ballot 3 Q2)."""
        self.session.agent(A, 'Stop at 90 calls.', 14)
        self.assertEqual((self.beat('--interval', '300')[:6], self.slept()), ('QUIET ', ['300']))
        self.session.agent(A, 'Stop at 90 calls.', 15)
        self.assertEqual((self.beat('--interval', '300')[:6], self.slept()), ('QUIET ', ['60'] * 5))

    def test_a_crossing_during_the_wait_ends_it_at_the_next_minute(self):
        self.session.agent(A, 'Stop at 30 calls.', 20)
        later = transcript('Stop at 30 calls.', 30, self.session.when, False, 10_000)
        (self.swap / '2').write_text(''.join(json.dumps(e) + '\n' for e in later))
        lines = self.beat('--interval', '300').splitlines()
        self.assertEqual((lines[0][:6], lines[1:], self.slept()), ('ALARM ', ['CALLS %s 30/30' % A], ['60', '60']))

    def test_an_agent_told_to_stop_or_ended_keeps_the_usual_wait_and_the_limits_are_options(self):
        self.session.agent(A, 'Stop at 30 calls.', 20)
        self.session.agent(B, 'Stop at 30 calls.', 25)
        (self.records / 'stop_sent.txt').write_text(A + '\n')
        (self.records / 'done_ids.txt').write_text(B + '\n')
        self.assertEqual((self.beat('--interval', '300')[:6], self.slept()), ('QUIET ', ['300']))
        (self.records / 'stop_sent.txt').write_text('')
        (self.records / 'done_ids.txt').write_text('')
        self.assertEqual(self.beat('--interval', '300', '--near-calls', '4')[:6], 'QUIET ')
        self.assertEqual(self.slept(), ['300'])
        self.assertEqual(self.beat('--interval', '300', '--near-calls', '10', '--near-s', '100')[:6], 'QUIET ')
        self.assertEqual(self.slept(), ['100'] * 3)

    def test_the_script_has_no_syntax_error(self):
        self.assertEqual(subprocess.run(['bash', '-n', str(HEARTBEAT)], capture_output=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
