"""Tests for scripts/session/memwatch.py, the memory watch that writes an alarm file and ends nothing.

The tests feed canned command output through an injected runner, a fake clock and a fake sleep, so nothing reads the
live machine and no signal is sent.
"""
import contextlib
import importlib.util
import io
import itertools
import os
from pathlib import Path
import tempfile
import types
import unittest

SCRIPT = Path(__file__).parents[1] / 'session' / 'memwatch.py'
SWAP = 'total = 12288.00M  used = 11000.50M  free = 1287.50M  (encrypted)'
SWAP_HIGH = 'total = 12288.00M  used = 12000.00M  free = 288.00M  (encrypted)'
VM_STAT = ('Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 100.\n'
           'Pages stored in compressor: 6553600.\n')
TOP = 'Processes: 500 total\nLoad Avg: 1.0\nPID    UID  MEM\n401    501  20G\n402    0    1500M+\n403    501  300K-\n'
TOP_SMALL = 'Processes: 5 total\nPID    UID  MEM\n401    501  2G\n'
OURS_COMMAND = '/work/lane-1/.build/debug/LungfishApp --flag'


def load():
    spec = importlib.util.spec_from_file_location('memwatch', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def runner_for(swap=SWAP, level='1', top=TOP, calls=None):
    """A stand-in for the command runner. It answers from canned text and records each command."""
    def runner(command):
        if calls is not None:
            calls.append(command)
        if command[0] == 'sysctl':
            return swap if command[-1] == 'vm.swapusage' else level
        if command[0] == 'top':
            return top
        if command[0] == 'vm_stat':
            return VM_STAT
        if command[:3] == ['ps', '-o', 'comm=']:
            return '/usr/bin/name' + command[-1]
        return OURS_COMMAND if command[-1] == '401' else '/usr/sbin/other ' + command[-1]
    return runner


def limits(**over):
    values = dict(swap_pct=90, pressure_level=2, compressor_gb=100, proc_gb=16)
    values.update(over)
    return types.SimpleNamespace(**values)


def reading(swap=(12288.0, 6000.0, 6288.0), level=1, compressor=10.0, procs=()):
    return {'swap': swap, 'level': level, 'compressor': compressor,
            'procs': [{'pid': p, 'uid': 501, 'mib': g * 1024.0, 'name': 'proc%d' % p} for p, g in procs]}


class ParseAndEvaluateTests(unittest.TestCase):
    def setUp(self):
        self.m = load()

    def kinds(self, lines):
        return [line.split()[0] for line in lines]

    def test_parsers_read_canned_command_output(self):
        m = self.m
        self.assertEqual(m.parse_swap(SWAP), (12288.0, 11000.5, 1287.5))
        self.assertEqual(m.parse_swap(''), (0.0, 0.0, 0.0))
        self.assertEqual([m.to_mib(text) for text in ('512K', '1234M+', '2G', '1T', '1048576', '?')],
                         [0.5, 1234.0, 2048.0, 1048576.0, 1.0, 0.0])
        self.assertEqual(m.parse_top(TOP), [(401, 501, 20480.0), (402, 0, 1500.0), (403, 501, 300 / 1024)])
        self.assertEqual(m.parse_top('401 501 20G\n'), [])
        self.assertEqual(m.parse_compressor_gib(VM_STAT), 100.0)
        self.assertEqual(m.parse_compressor_gib(VM_STAT.replace('16384', '4096')), 25.0)
        self.assertEqual(m.parse_compressor_gib(''), 0.0)

    def test_quiet_below_every_line(self):
        self.assertEqual(self.m.evaluate(reading(procs=[(401, 8)]), limits(), [], lambda pid: ''), [])

    def test_each_limit_gives_one_line_and_only_big_processes_are_asked_about(self):
        asked = []

        def command_of(pid):
            asked.append(pid)
            return OURS_COMMAND if pid == 401 else '/usr/sbin/other'

        busy = reading(swap=(12288.0, 12000.0, 288.0), level=2, compressor=120.0,
                       procs=[(401, 20), (402, 30), (403, 1)])
        lines = self.m.evaluate(busy, limits(), ['/work/lane-1'], command_of)
        self.assertEqual(self.kinds(lines), ['SWAP', 'PRESSURE', 'RUNAWAY', 'BIGPROC', 'COMPRESSOR'])
        self.assertEqual(asked, [401, 402])
        self.assertIn(OURS_COMMAND, lines[2])
        self.assertIn('top: proc401', lines[4])

    def test_limits_are_arguments(self):
        lines = self.m.evaluate(reading(swap=(12288.0, 6144.0, 6144.0), procs=[(401, 8)]),
                                limits(swap_pct=40, pressure_level=1, proc_gb=4, compressor_gb=5), [], lambda pid: 'x')
        self.assertEqual(self.kinds(lines), ['SWAP', 'PRESSURE', 'BIGPROC', 'COMPRESSOR'])


class RunTests(unittest.TestCase):
    def setUp(self):
        self.m = load()
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name) / 'llm'

    def run_main(self, runner, *args, sleep=None):
        clock = itertools.count(2_000_000_000.0, 60.0).__next__
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = self.m.main(['--dir', str(self.dir), *args], runner=runner,
                               sleep=sleep or (lambda seconds: None), clock=clock)
        return code, out.getvalue()

    def test_collect_reads_with_read_only_commands(self):
        calls = []
        got = self.m.collect(runner_for(level='2', calls=calls), 3)
        self.assertEqual((got['level'], got['swap'], got['compressor']), (2, (12288.0, 11000.5, 1287.5), 100.0))
        self.assertEqual([p['name'] for p in got['procs']], ['name401', 'name402', 'name403'])
        self.assertEqual({call[0] for call in calls}, {'sysctl', 'top', 'ps', 'vm_stat'})
        self.assertEqual([call for call in calls if call[0] == 'top'][0][-2:], ['-n', '3'])

    def test_main_writes_the_alarm_then_empties_it(self):
        seen = []
        alarm = self.dir / 'memwatch.alarm'

        def runner(command):
            return runner_for(swap=SWAP if seen else SWAP_HIGH, top=TOP_SMALL)(command)

        code, out = self.run_main(runner, '--rounds', '2', sleep=lambda seconds: seen.append(alarm.read_text()))
        self.assertEqual(code, 0)
        self.assertIn('SWAP 98% used', seen[0])
        self.assertEqual(alarm.read_text(), '')
        log = (self.dir / 'memwatch.log').read_text().splitlines()
        self.assertEqual(len(log), 2)
        self.assertIn('ALARM SWAP', log[0])
        self.assertIn(' | ok | ', log[1])
        self.assertIn('started pid %d' % os.getpid(), out)
        self.assertIn('stopped after 2 rounds', out)
        self.assertEqual((self.dir / 'memwatch.pid').read_text().strip(), str(os.getpid()))

    def test_a_stop_file_made_after_the_start_ends_the_loop(self):
        stop = self.dir / 'memwatch.stop'

        def sleep(seconds):
            stop.write_text('')
            os.utime(stop, (2_100_000_000, 2_100_000_000))

        out = self.run_main(runner_for(top=TOP_SMALL), '--rounds', '5', sleep=sleep)[1]
        self.assertIn('stopped after 1 rounds', out)

    def test_an_older_stop_file_is_ignored(self):
        self.dir.mkdir(parents=True)
        stop = self.dir / 'memwatch.stop'
        stop.write_text('')
        os.utime(stop, (1_900_000_000, 1_900_000_000))
        out = self.run_main(runner_for(top=TOP_SMALL), '--rounds', '2')[1]
        self.assertIn('stopped after 2 rounds', out)

    def test_ours_file_names_a_runaway(self):
        ours = self.dir.parent / 'ours.txt'
        ours.write_text('# worktrees\n\n/work/lane-1\n')
        self.run_main(runner_for(), '--rounds', '1', '--ours', str(ours))
        text = (self.dir / 'memwatch.alarm').read_text()
        self.assertIn('RUNAWAY name401 pid 401 uid 501 at 20.0 GiB', text)

    def test_only_read_only_commands_run_and_no_signal_exists_in_the_source(self):
        calls = []
        self.run_main(runner_for(calls=calls), '--rounds', '1')
        self.assertTrue({call[0] for call in calls} <= {'sysctl', 'top', 'ps', 'vm_stat'})
        source = SCRIPT.read_text()
        for banned in ('pk' + 'ill', 'kill' + 'all', 'os.kill', 'import signal', 'sudo', 'tmutil'):
            self.assertNotIn(banned, source)


if __name__ == '__main__':
    unittest.main()
