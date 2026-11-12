"""Tests for scripts/session/run_gates.py, the read-only runner for the ratchets and checks of a worktree.

Each test builds its own small tree of gate scripts in a temporary folder and never scans or edits the real tree.
"""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).parents[1] / 'session' / 'run_gates.py'
FILES = {
    'scripts/ratchets/alpha.sh': '#!/usr/bin/env python3\nimport os\nprint("alpha", os.environ["LUNGFISH_RATCHET_READ_ONLY"])\n',
    'scripts/ratchets/beta.sh': '#!/bin/bash\necho beta-ran\nexit %d\n',
    'scripts/ratchets/ratchet_baseline.py': 'open("helper-ran", "w").close()\n',
    'scripts/checks/one.py': 'print("check one")\n',
    'scripts/testing/preferences-leaks.py': 'import sys\nprint("lint args", sys.argv[1:])\n',
}
LABELS = ['scripts/ratchets/alpha.sh', 'scripts/ratchets/beta.sh', 'scripts/checks/one.py',
          'scripts/testing/preferences-leaks.py lint']


def load():
    spec = importlib.util.spec_from_file_location('run_gates', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RunGatesTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / 'tree'
        self.log = Path(tmp.name) / 'gates.log'
        self.module = load()

    def build(self, beta_status=0):
        for rel, text in FILES.items():
            path = self.root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text % beta_status if rel.endswith('beta.sh') else text)

    def gates(self, *extra):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = self.module.main([str(self.log), '--root', str(self.root), *extra])
        lines = self.log.read_text().splitlines() if self.log.exists() else []
        return code, out.getvalue(), lines

    def test_list_prints_the_sequence_and_runs_nothing(self):
        self.build()
        code, out, _ = self.gates('--list')
        self.assertEqual((code, out.splitlines()), (0, LABELS))
        self.assertFalse(self.log.exists())

    def test_all_green_log_ends_with_exit_0_and_runs_read_only(self):
        self.build()
        code, out, lines = self.gates()
        self.assertEqual(code, 0)
        self.assertEqual([line for line in lines if line.startswith('exit=')], ['exit=0'])
        self.assertEqual(lines[-1], 'exit=0')
        self.assertEqual(sum(line.startswith('status=0 ') for line in lines), 4)
        order = [lines.index(text) for text in ('alpha 1', 'beta-ran', 'check one', "lint args ['lint']")]
        self.assertEqual(order, sorted(order))
        self.assertIn('failed=0 of 4', lines)
        self.assertIn('failed=0 of 4', out)
        self.assertFalse((self.root / 'helper-ran').exists())

    def test_a_red_script_gives_exit_1_and_later_scripts_still_run(self):
        self.build(beta_status=4)
        code, out, lines = self.gates()
        self.assertEqual(code, 1)
        self.assertEqual(lines[-1], 'exit=1')
        self.assertTrue(any(line.startswith('status=4 ') for line in lines))
        self.assertIn('check one', lines)
        self.assertIn('failed=1 of 4', lines)

    def test_a_script_that_cannot_start_is_status_127(self):
        self.build()
        with mock.patch.object(self.module.subprocess, 'run', side_effect=OSError('boom')):
            code, _, lines = self.gates()
        self.assertEqual(code, 1)
        self.assertIn('could not start: boom', lines)
        self.assertEqual(sum(line.startswith('status=127 ') for line in lines), 4)

    def test_interpreter_follows_the_first_line_then_the_suffix(self):
        want = {'a.sh': (['#!/usr/bin/env python3'], [sys.executable]), 'b.sh': (['#!/bin/bash'], ['bash']),
                'c.sh': (['echo hi'], ['bash']), 'd.py': (['print(1)'], [sys.executable]),
                'e.sh': (['#!/bin/sh'], ['bash'])}
        self.root.mkdir(parents=True)
        for name, (first, expected) in want.items():
            (self.root / name).write_text(first[0] + '\n')
            self.assertEqual(self.module.interpreter(str(self.root / name)), expected, name)
        self.assertEqual(self.module.interpreter(str(self.root / 'missing.py')), [sys.executable])

    def test_usage_error_exits_2(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
            self.module.main([])
        self.assertEqual(caught.exception.code, 2)

    def test_script_runs_from_the_command_line_and_names_no_process_killers(self):
        self.build()
        done = subprocess.run([sys.executable, str(SCRIPT), str(self.log), '--root', str(self.root)],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0)
        self.assertEqual(self.log.read_text().splitlines()[-1], 'exit=0')
        source = SCRIPT.read_text()
        for banned in ('pk' + 'ill', 'kill' + 'all'):
            self.assertNotIn(banned, source)


if __name__ == '__main__':
    unittest.main()
