"""Tests for scripts/session/heartbeat.sh, the manager's background wait.

Each test runs the script for one round with no sleep against a temporary project folder, a temporary records folder
and stand-ins for df and ps placed first on PATH, so no test reads the live disk or the live process list.
"""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).parents[1] / 'session' / 'heartbeat.sh'
SID = 'sess-1'
FAKE_DF = '\n'.join([
    '#!/bin/sh',
    'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"',
    'echo "/dev/fake 999999999 1 $FAKE_DF_KB 1% /"',
    ''])
FAKE_PS = '\n'.join([
    '#!/bin/sh',
    'if [ "$2" = "$FAKE_ALIVE_PID" ]; then echo "python3 /x/memwatch.py --dir d"; exit 0; fi',
    'exit 1',
    ''])
OLD, NEW = 'a0123456789abcdef', 'b0123456789abcdef'


class HeartbeatTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        self.project, self.records, self.bin = root / 'project', root / 'records', root / 'bin'
        self.sub = self.project / SID / 'subagents'
        for folder in (self.sub, self.records, self.bin):
            folder.mkdir(parents=True)
        for name, text in (('df', FAKE_DF), ('ps', FAKE_PS)):
            (self.bin / name).write_text(text)
            (self.bin / name).chmod(0o755)
        self.free_gb = 500
        self.alive = str(os.getpid())
        (self.records / 'memwatch.pid').write_text(self.alive + '\n')

    def agent(self, aid, tokens, age=0, final=False, model=None):
        when = datetime.now(timezone.utc) - timedelta(seconds=age)
        tool = {'type': 'tool_use', 'id': 't', 'name': 'Bash', 'input': {}}
        content = [{'type': 'text', 'text': 'Done.'}] if final else [tool]
        usage = {'input_tokens': 5, 'cache_read_input_tokens': tokens, 'cache_creation_input_tokens': 0}
        entry = {'type': 'assistant', 'uuid': 'u-' + aid, 'timestamp': when.strftime('%Y-%m-%dT%H:%M:%S.000Z'),
                 'message': {'id': 'm-' + aid, 'content': content, 'usage': usage, **({'model': model} if model else {})}}
        (self.sub / ('agent-%s.jsonl' % aid)).write_text(json.dumps(entry) + '\n')

    def beat(self, *extra):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'], PYTHON=sys.executable,
                   FAKE_DF_KB=str(self.free_gb * 1048576), FAKE_ALIVE_PID=self.alive)
        command = ['bash', str(SCRIPT), '--project', str(self.project), '--session', SID, '--records',
                   str(self.records), '--interval', '0', '--rounds', '1', *extra]
        done = subprocess.run(command, capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout

    def test_quiet_when_nothing_is_found(self):
        self.agent(OLD, 100_000)
        out = self.beat()
        self.assertTrue(out.startswith('QUIET '), out)
        self.assertTrue(out.endswith('disk 500Gi\n'), out)

    def test_context_over_the_line_alarms_and_the_line_is_an_argument(self):
        self.agent(OLD, 295_000)
        out = self.beat()
        self.assertTrue(out.startswith('ALARM '), out)
        self.assertIn(OLD, out)
        self.assertTrue(self.beat('--ctx-k', '300').startswith('QUIET'))

    def test_final_agents_and_listed_done_ids_are_ignored(self):
        self.agent(OLD, 350_000, final=True)
        self.agent(NEW, 350_000)
        (self.records / 'done_ids.txt').write_text(NEW + '\n')
        self.assertTrue(self.beat().startswith('QUIET'))

    def test_an_opus_agent_uses_the_higher_line_by_the_model_its_transcript_names(self):
        opus, sonnet = 'claude-opus-5-5', 'claude-sonnet-5-5'
        self.agent(OLD, 350_000, model=opus)
        self.agent(NEW, 100_000, model=sonnet)
        self.assertTrue(self.beat().startswith('QUIET'))
        self.agent(OLD, 395_000, model=opus)
        self.assertIn(OLD, self.beat())
        self.agent(OLD, 350_000, model=opus)
        self.agent(NEW, 295_000, model=sonnet)
        out = self.beat()
        self.assertEqual((NEW in out, OLD in out), (True, False))
        self.assertTrue(self.beat('--ctx-k', '300').startswith('QUIET'))
        out = self.beat('--ctx-k', '300', '--opus-ctx-k', '350')
        self.assertEqual((NEW in out, OLD in out), (False, True))

    def test_a_list_of_opus_ids_no_longer_sets_a_line(self):
        (self.records / 'opus_ids.txt').write_text(OLD + '\n')
        self.agent(OLD, 350_000, model='claude-sonnet-5-5')
        self.assertIn(OLD, self.beat())

    def test_stalled_agent_alarms(self):
        self.agent(OLD, 50_000, age=2000)
        self.assertIn('STALLED ' + OLD, self.beat())
        self.assertTrue(self.beat('--pending-s', '5000').startswith('QUIET'))

    def test_disk_under_the_line(self):
        self.free_gb = 50
        self.assertIn('DISK 50Gi free', self.beat())
        self.assertTrue(self.beat('--disk-min-gb', '40').startswith('QUIET'))

    def test_memwatch_alarm_is_printed_until_acknowledged(self):
        alarm, ack = self.records / 'memwatch.alarm', self.records / 'memwatch.ack'
        alarm.write_text('2026-11-12 10:00:00 | SWAP 95% used\n')
        self.assertIn('SWAP 95% used', self.beat())
        ack.write_text('')
        self.assertTrue(self.beat().startswith('QUIET'))
        old = datetime.now().timestamp() - 2 * 3600
        os.utime(ack, (old, old))
        self.assertIn('SWAP 95% used', self.beat())
        alarm.write_text('')
        self.assertTrue(self.beat().startswith('QUIET'))

    def test_memwatch_not_running(self):
        pid, stop = self.records / 'memwatch.pid', self.records / 'memwatch.stop'
        pid.write_text('999999\n')
        self.assertIn('MEMWATCH NOT RUNNING', self.beat())
        self.assertTrue(self.beat('--no-memwatch').startswith('QUIET'))
        stop.write_text('')
        later = datetime.now().timestamp() + 100
        os.utime(stop, (later, later))
        self.assertTrue(self.beat().startswith('QUIET'))

    def manager(self, *blocks, **fields):
        """A main transcript of the session, a prompt that names a computer-use tool, then one assistant entry for each
        block. FIELDS go on every assistant entry."""
        when = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
        prompt = {'role': 'user', 'content': 'Never call mcp__computer-use__request_access here.'}
        lines = [json.dumps({'type': 'user', 'uuid': 'p', 'timestamp': when, 'message': prompt})]
        for n, block in enumerate(blocks):
            message = {'id': 'm%d' % n, 'role': 'assistant', 'content': [block]}
            lines.append(json.dumps({'type': 'assistant', 'uuid': 'a%d' % n, 'timestamp': when, 'message': message,
                                     **fields}))
        (self.project / (SID + '.jsonl')).write_text('\n'.join(lines) + '\n')

    @staticmethod
    def use(name, tid, **given):
        return {'type': 'tool_use', 'id': tid, 'name': name, 'input': given}

    def test_a_computer_use_call_in_the_manager_s_transcript_acts_once(self):
        """E-RUN-59 bars computer-use in the manager, which still loaded it and called request_access twice at 21:29:34
        and 23:10:27 on 2026-11-16 (O177 ballot 6 Q2, E-RUN-64)."""
        self.manager(self.use('ToolSearch', 'toolu_01search', query='computer-use'),
                     self.use('mcp__computer-use__request_access', 'toolu_01access', apps=['Lungfish']))
        lines = self.beat().splitlines()
        self.assertTrue(lines[0].startswith('ALARM '), lines)
        acts = [line for line in lines if line.startswith('ACT ')]
        self.assertEqual(len(acts), 1, lines)
        self.assertIn(' mcp__computer-use__request_access ', acts[0])
        self.assertTrue(acts[0].endswith(' toolu_01access'), acts[0])
        self.assertTrue(self.beat().startswith('QUIET'))
        self.manager(self.use('mcp__computer-use__request_access', 'toolu_01access'),
                     self.use('mcp__computer-use__screenshot', 'toolu_02shot'))
        acts = [line for line in self.beat().splitlines() if line.startswith('ACT ')]
        self.assertEqual([line.split()[-1] for line in acts], ['toolu_02shot'])
        self.assertEqual((self.records / 'act_seen.txt').read_text().split(), ['toolu_01access', 'toolu_02shot'])

    def test_no_act_for_other_tools_a_mention_or_a_subagent_s_computer_use(self):
        self.manager(self.use('Bash', 'toolu_01bash', command='echo mcp__computer-use__request_access'),
                     self.use('mcp__Claude_in_Chrome__navigate', 'toolu_01chrome'),
                     self.use('mcp__Claude_Browser__click', 'toolu_01browser'))
        self.assertTrue(self.beat().startswith('QUIET'))
        self.manager(self.use('mcp__computer-use__request_access', 'toolu_01side'), isSidechain=True)
        self.assertTrue(self.beat().startswith('QUIET'))
        self.manager(self.use('mcp__computer-use__request_access', 'toolu_01agent'), agentId='a1')
        self.assertTrue(self.beat().startswith('QUIET'))
        walker = {'type': 'assistant', 'uuid': 's', 'message': {
            'id': 's', 'content': [self.use('mcp__computer-use__request_access', 'toolu_01walker')]}}
        (self.sub / ('agent-%s.jsonl' % NEW)).write_text(json.dumps(walker) + '\n')
        self.manager()
        self.assertTrue(self.beat().startswith('QUIET'))

    def test_bad_arguments_exit_2(self):
        base = ['--project', 'p', '--session', 's']
        for extra in ([], ['--project'], ['--bogus', 'x'], base + ['--near-s', '0'], base + ['--near-s', 'soon'],
                      base + ['--near-calls', '-1'], base + ['--near-calls', 'many']):
            done = subprocess.run(['bash', str(SCRIPT), *extra], capture_output=True, text=True)
            self.assertEqual(done.returncode, 2)
            self.assertIn('usage: heartbeat.sh', done.stderr)

    def test_source_names_no_process_killers(self):
        source = SCRIPT.read_text()
        for banned in ('pk' + 'ill', 'kill' + 'all', 'kill '):
            self.assertNotIn(banned, source)


if __name__ == '__main__':
    unittest.main()
