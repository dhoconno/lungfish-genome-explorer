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

    def agent(self, aid, tokens, age=0, final=False):
        when = datetime.now(timezone.utc) - timedelta(seconds=age)
        tool = {'type': 'tool_use', 'id': 't', 'name': 'Bash', 'input': {}}
        content = [{'type': 'text', 'text': 'Done.'}] if final else [tool]
        usage = {'input_tokens': 5, 'cache_read_input_tokens': tokens, 'cache_creation_input_tokens': 0}
        entry = {'type': 'assistant', 'uuid': 'u-' + aid, 'timestamp': when.strftime('%Y-%m-%dT%H:%M:%S.000Z'),
                 'message': {'id': 'm-' + aid, 'content': content, 'usage': usage}}
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

    def test_opus_ids_use_the_higher_line(self):
        (self.records / 'opus_ids.txt').write_text(OLD + '\n')
        self.agent(OLD, 350_000)
        self.agent(NEW, 100_000)
        self.assertTrue(self.beat().startswith('QUIET'))
        self.agent(OLD, 395_000)
        self.assertIn(OLD, self.beat())
        self.agent(NEW, 295_000)
        self.assertIn(NEW, self.beat())

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

    def test_bad_arguments_exit_2(self):
        for extra in ([], ['--project'], ['--bogus', 'x']):
            done = subprocess.run(['bash', str(SCRIPT), *extra], capture_output=True, text=True)
            self.assertEqual(done.returncode, 2)
            self.assertIn('usage: heartbeat.sh', done.stderr)

    def test_source_names_no_process_killers(self):
        source = SCRIPT.read_text()
        for banned in ('pk' + 'ill', 'kill' + 'all', 'kill '):
            self.assertNotIn(banned, source)


if __name__ == '__main__':
    unittest.main()
