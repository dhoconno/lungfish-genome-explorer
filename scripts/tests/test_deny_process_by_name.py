"""Tests for .claude/hooks/deny_process_by_name.py, the PreToolUse hook that refuses pkill and killall.

Each test feeds the hook input JSON to the script on stdin, as Claude Code does, and checks the exit code and the
output. The script runs under /usr/bin/python3 -I, the interpreter that .claude/settings.json names, when this Mac
has it, so a run also proves that the script starts there. No test runs pkill, killall or kill.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HOOK = ROOT / '.claude' / 'hooks' / 'deny_process_by_name.py'
SETTINGS = ROOT / '.claude' / 'settings.json'
PYTHON = '/usr/bin/python3' if os.access('/usr/bin/python3', os.X_OK) else sys.executable

# Refused, the first group of the panel's test text, in its order.
REFUSED = [
    'pkill -f swift-build',
    'killall swift-build',
    '/usr/bin/pkill -f x',
    '/usr/bin/pkill x',
    'ls; pkill -f x',
    'true && killall x',
    'cd build && killall swift-build',
    'sudo pkill y',
    'pgrep -f swift-build | xargs kill',
    'kill $(pgrep -f swift-build)',
]

# Refused as well, the forms that a skipped word, a split point or the quoting could hide.
REFUSED_HIDDEN = [
    'pkill',
    'echo done\npkill -f x',
    'true && \\\npkill x',
    'echo a#b; pkill x',
    'true||pkill x',
    'sleep 1 & pkill x',
    '(pkill x)',
    'if true; then pkill x; fi',
    'FOO=1 pkill x',
    'env FOO=1 pkill x',
    'env -i -u HOME pkill x',
    '/usr/bin/env pkill x',
    'sudo -u root pkill x',
    'sudo -- killall x',
    'command pkill x',
    'exec pkill x',
    'nohup pkill x &',
    'time pkill x',
    'time -p killall x',
    '"pkill" -f x',
    '\\pkill x',
    'echo x | xargs pkill',
    'pgrep -f x | xargs -n 1 kill',
    'pgrep -f x | xargs -I{} kill -9 {}',
    'kill `pgrep -f x`',
    'sudo kill -9 $(pgrep -f x)',
]

# Allowed, the second group of the panel's test text, in its order.
ALLOWED = [
    "rg -n 'pkill|killall' docs/contracts/RUNNING-A-PHASE-SESSION.md",
    'rg -n pkill docs/contracts',
    'grep -c pkill notes.md',
    'echo "killall"',
    'kill 12345',
    'lsof -a -c swift-build -d cwd',
    'git commit -F msg.txt',
]

# Allowed as well, the searches and look-ups that name a program without running it.
ALLOWED_NAMING = [
    'command -v pkill',
    'pgrep -f swift-build',
    "git commit -m 'Ban pkill; use lsof instead'",
    'rg -n pkill scripts | head -5',
    'echo hi # pkill x',
    'kill -9 4242 && echo stopped',
    'ls pkill.txt killall.txt',
    'echo $(date)',
]

# Fault, the third group of the panel's test text, then more inputs that must not block a Bash call.
FAULTS = [
    ('no command', json.dumps({'tool_name': 'Bash', 'tool_input': {}})),
    ('no tool_input', json.dumps({'tool_name': 'Bash'})),
    ('another tool', json.dumps({'tool_name': 'Write', 'tool_input': {'file_path': 'notes.md', 'content': 'pkill x'}})),
    ('another tool with a command', json.dumps({'tool_name': 'Task', 'tool_input': {'command': 'pkill -f x'}})),
    ('not JSON', 'pkill -f swift-build'),
    ('a command that is not text', json.dumps({'tool_name': 'Bash', 'tool_input': {'command': ['pkill', 'x']}})),
    ('a command that does not parse', json.dumps({'tool_name': 'Bash', 'tool_input': {'command': 'echo "pkill -f x'}})),
    ('JSON that is not an object', '[]'),
    ('empty input', ''),
]


def run_hook(stdin_text):
    return subprocess.run([PYTHON, '-I', str(HOOK)], input=stdin_text, capture_output=True, text=True, timeout=30)


def hook_input(command):
    return json.dumps({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'tool_input': {'command': command}})


class PatternKillHookTests(unittest.TestCase):
    def assert_refused(self, command):
        result = run_hook(hook_input(command))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        output = json.loads(result.stdout)
        self.assertEqual(list(output), ['hookSpecificOutput'])
        decision = output['hookSpecificOutput']
        self.assertEqual(decision['hookEventName'], 'PreToolUse')
        self.assertEqual(decision['permissionDecision'], 'deny')
        reason = decision['permissionDecisionReason']
        self.assertIn('Own processes only', reason)
        self.assertIn('lsof -a -c swift-build -d cwd', reason)
        self.assertIn('by its PID', reason)

    def assert_silent(self, stdin_text):
        result = run_hook(stdin_text)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, '')

    def test_refuses_the_commands_of_the_panel_text(self):
        for command in REFUSED:
            with self.subTest(command=command):
                self.assert_refused(command)

    def test_refuses_what_skipped_words_split_points_and_quoting_could_hide(self):
        for command in REFUSED_HIDDEN:
            with self.subTest(command=command):
                self.assert_refused(command)

    def test_allows_searches_and_kills_by_pid_with_no_output(self):
        for command in ALLOWED:
            with self.subTest(command=command):
                self.assert_silent(hook_input(command))

    def test_allows_commands_that_only_name_a_refused_program(self):
        for command in ALLOWED_NAMING:
            with self.subTest(command=command):
                self.assert_silent(hook_input(command))

    def test_a_fault_exits_zero_with_no_output(self):
        for label, stdin_text in FAULTS:
            with self.subTest(label=label):
                self.assert_silent(stdin_text)

    def test_registration_runs_this_script_and_holds_nothing_else(self):
        settings = json.loads(SETTINGS.read_text(encoding='utf-8'))
        self.assertEqual(list(settings), ['hooks'])
        self.assertEqual(list(settings['hooks']), ['PreToolUse'])
        entries = settings['hooks']['PreToolUse']
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]['matcher'], 'Bash')
        self.assertEqual(entries[0]['hooks'], [{
            'type': 'command',
            'command': '/usr/bin/python3 -I "$CLAUDE_PROJECT_DIR/.claude/hooks/deny_process_by_name.py" || true',
            'timeout': 10,
        }])
        self.assertTrue(HOOK.is_file())

    def test_registered_command_exits_zero_when_the_script_is_missing(self):
        # Python exits with status 2 for a script file that is not there, and Claude Code treats exit 2 of a
        # PreToolUse command as a block, so the registration ends in || true. A refusal travels as JSON on stdout.
        settings = json.loads(SETTINGS.read_text(encoding='utf-8'))
        command = settings['hooks']['PreToolUse'][0]['hooks'][0]['command']
        with tempfile.TemporaryDirectory() as empty_project:
            result = subprocess.run(
                ['/bin/sh', '-c', command],
                input=hook_input('ls'),
                capture_output=True,
                text=True,
                timeout=30,
                env={'CLAUDE_PROJECT_DIR': empty_project, 'PATH': '/usr/bin:/bin'},
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
