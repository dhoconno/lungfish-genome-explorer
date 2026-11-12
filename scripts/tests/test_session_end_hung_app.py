"""Tests for scripts/session/end_hung_app.py, which ends one hung Lungfish app by PID.

A stand-in machine supplies the process list and records every signal, so no test reads the live process list and no
test sends a signal to a real process.
"""
import contextlib
import importlib.util
import io
from pathlib import Path
import signal
import unittest

SCRIPT = Path(__file__).parents[1] / 'session' / 'end_hung_app.py'
PS = '\n'.join([
    '  101   501  204800 /Applications/Lungfish.app/Contents/MacOS/Lungfish',
    '  102   501   10240 /Applications/Lungfish.app/Contents/Resources/bin/samtools',
    '  103   501  512000 /Applications/Lungfish Preview.app/Contents/MacOS/Lungfish Preview',
    '  104   502  300000 /Applications/Lungfish Debug.app/Contents/MacOS/Lungfish',
    '  105   501    5000 /usr/bin/python3',
    '  106   501   99999 /Users/me/Lungfish.app.backup/notes',
    'garbage line',
    ''])
TERM, KILL = signal.SIGTERM, signal.SIGKILL
PREVIEW = '/Applications/Lungfish Preview.app/Contents/MacOS/Lungfish Preview'


def load():
    spec = importlib.util.spec_from_file_location('end_hung_app', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeMachine:
    """Process list and signals held in memory. behavior maps a signal to remove, reuse or ignore."""

    def __init__(self, rows, uid=501, behavior=None):
        self.rows, self.user, self.signals, self.slept = list(rows), uid, [], []
        self.behavior = behavior or {TERM: 'remove', KILL: 'remove'}

    def processes(self):
        return list(self.rows)

    def uid(self):
        return self.user

    def send(self, pid, number):
        self.signals.append((pid, number))
        action = self.behavior.get(number, 'ignore')
        if action == 'remove':
            self.rows = [row for row in self.rows if row[0] != pid]
        elif action == 'reuse':
            self.rows = [(row[0], row[1], row[2], '/usr/bin/other') if row[0] == pid else row for row in self.rows]

    def sleep(self, seconds):
        self.slept.append(seconds)


class EndHungAppTests(unittest.TestCase):
    def setUp(self):
        self.module = load()
        self.rows = self.module.parse_ps(PS)

    def go(self, *argv, **machine_options):
        machine = FakeMachine(self.rows, **machine_options)
        lines = []
        code = self.module.main(list(argv), machine=machine, out=lines.append)
        return code, lines, machine

    def test_parse_ps_keeps_paths_with_spaces_and_skips_garbage(self):
        self.assertEqual(len(self.rows), 6)
        self.assertEqual(self.rows[2], (103, 501, 512000, PREVIEW))

    def test_list_names_apps_and_helpers_only(self):
        code, lines, machine = self.go('--list')
        self.assertEqual(code, 0)
        self.assertEqual([line.split()[1] for line in lines], ['101', '102', '103', '104'])
        self.assertEqual([line.split()[7] for line in lines], ['app', 'helper', 'app', 'app'])
        self.assertIn('rss 200 MiB', lines[0])
        self.assertEqual(machine.signals, [])
        only = self.go('--list', '--bundle', 'Lungfish Preview.app')[1]
        self.assertEqual([line.split()[1] for line in only], ['103'])
        self.assertEqual(self.go('--list', '--bundle', 'Other.app')[1], ['none'])

    def test_dry_run_sends_nothing(self):
        code, lines, machine = self.go('101')
        self.assertEqual(code, 0)
        self.assertTrue(lines[0].startswith('DRY RUN would send SIGTERM to pid 101'))
        self.assertEqual(machine.signals, [])

    def test_refuses_a_helper_a_foreign_program_and_another_users_app(self):
        for pid in ('102', '105', '106'):
            code, lines, machine = self.go(pid, '--execute')
            self.assertEqual((code, machine.signals), (4, []), pid)
            self.assertTrue(lines[0].startswith('REFUSED'), pid)
        code, lines, machine = self.go('104', '--execute')
        self.assertEqual((code, machine.signals), (4, []))
        self.assertIn('uid 502', lines[0])

    def test_unknown_pid_is_not_found(self):
        code, lines, machine = self.go('999', '--execute')
        self.assertEqual((code, lines, machine.signals), (3, ['NOT FOUND pid 999'], []))

    def test_sigterm_ends_the_app(self):
        code, lines, machine = self.go('101', '--execute')
        self.assertEqual((code, machine.signals), (0, [(101, TERM)]))
        self.assertEqual(lines, ['ENDED pid 101 with SIGTERM'])

    def test_sigkill_follows_only_when_sigterm_is_ignored(self):
        code, lines, machine = self.go('103', '--execute', behavior={TERM: 'ignore', KILL: 'remove'})
        self.assertEqual((code, machine.signals), (0, [(103, TERM), (103, KILL)]))
        self.assertEqual(lines, ['ENDED pid 103 with SIGKILL after SIGTERM'])
        self.assertEqual(len(machine.slept), 21)

    def test_wait_is_an_argument(self):
        code, lines, machine = self.go('101', '--execute', '--wait', '3', behavior={TERM: 'ignore', KILL: 'remove'})
        self.assertEqual(code, 0)
        self.assertEqual(len(machine.slept), 4)

    def test_an_app_that_survives_both_signals_exits_5(self):
        code, lines, machine = self.go('101', '--execute', '--wait', '2', behavior={TERM: 'ignore', KILL: 'ignore'})
        self.assertEqual((code, machine.signals), (5, [(101, TERM), (101, KILL)]))
        self.assertEqual(lines, ['STILL RUNNING pid 101 after SIGKILL'])

    def test_a_reused_pid_gets_no_second_signal(self):
        code, lines, machine = self.go('101', '--execute', behavior={TERM: 'reuse'})
        self.assertEqual((code, machine.signals), (0, [(101, TERM)]))

    def test_argument_errors_exit_2(self):
        for argv in ([], ['--list', '101'], ['0'], ['-5'], ['101', '--wait', 'x']):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
                self.module.main(argv, machine=FakeMachine(self.rows), out=lambda line: None)
            self.assertEqual(caught.exception.code, 2, argv)

    def test_signals_are_sent_in_one_place_and_no_name_matching_tool_exists(self):
        source = SCRIPT.read_text()
        self.assertEqual(source.count('os.kill('), 1)
        for banned in ('pk' + 'ill', 'kill' + 'all', 'pgrep'):
            self.assertNotIn(banned, source)


if __name__ == '__main__':
    unittest.main()
