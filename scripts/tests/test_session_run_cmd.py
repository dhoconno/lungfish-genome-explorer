"""Tests for scripts/session/run_cmd.py, the logged command runner for blocking waits.

The commands are the running Python interpreter with a short program, so each test runs only what it starts itself.
"""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).parents[1] / 'session' / 'run_cmd.py'


def load():
    spec = importlib.util.spec_from_file_location('run_cmd', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RunCmdTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.log = self.dir / 'run.log'
        self.module = load()

    def run_py(self, program, *options):
        code = self.module.main([*options, str(self.log), sys.executable, '-c', program])
        return code, self.log.read_text().splitlines()

    def test_success_log_has_command_output_seconds_and_exit(self):
        code, lines = self.run_py('print("hello")')
        self.assertEqual(code, 0)
        self.assertTrue(lines[0].startswith('command: ' + sys.executable))
        self.assertEqual(lines[1], 'cwd: ' + os.getcwd())
        self.assertIn('hello', lines)
        self.assertTrue(lines[-2].startswith('seconds='))
        self.assertEqual([line for line in lines if line.startswith('exit=')], ['exit=0'])
        self.assertEqual(lines[-1], 'exit=0')

    def test_failing_command_logs_its_status_and_merges_stderr(self):
        code, lines = self.run_py('import sys; print("out"); sys.stderr.write("err\\n"); sys.exit(3)')
        self.assertEqual(code, 3)
        self.assertIn('out', lines)
        self.assertIn('err', lines)
        self.assertEqual(lines[-1], 'exit=3')

    def test_a_command_that_cannot_start_exits_127(self):
        code = self.module.main([str(self.log), str(self.dir / 'no-such-tool')])
        lines = self.log.read_text().splitlines()
        self.assertEqual(code, 127)
        self.assertTrue(any(line.startswith('could not start') for line in lines))
        self.assertEqual(lines[-1], 'exit=127')

    def test_a_signal_death_logs_128_plus_the_number(self):
        with mock.patch.object(self.module.subprocess, 'call', return_value=-9):
            code = self.module.main([str(self.log), 'anything'])
        self.assertEqual(code, 137)
        self.assertEqual(self.log.read_text().splitlines()[-1], 'exit=137')

    def test_developer_dir_default_override_and_empty(self):
        show = 'import os; print("DD=" + str(os.environ.get("DEVELOPER_DIR")))'
        with mock.patch.dict(os.environ, {'DEVELOPER_DIR': '/inherited'}):
            self.assertIn('DD=/Applications/Xcode.app/Contents/Developer', self.run_py(show)[1])
            self.assertIn('DD=/other', self.run_py(show, '--developer-dir', '/other')[1])
            self.assertIn('DD=/inherited', self.run_py(show, '--developer-dir', '')[1])

    def test_cwd_option_and_option_like_arguments_after_the_log_pass_through(self):
        program = 'import sys; print(sys.argv[1:])'
        code = self.module.main(['--cwd', str(self.dir), str(self.log), sys.executable, '-c', program, '--cwd', 'x'])
        text = self.log.read_text()
        self.assertEqual(code, 0)
        self.assertIn("['--cwd', 'x']", text)
        self.assertIn('cwd: ' + str(self.dir), text)

    def test_missing_log_or_command_exits_2(self):
        for argv in ([], [str(self.log)], ['--cwd', str(self.dir)]):
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                self.assertEqual(self.module.main(argv), 2)
            self.assertIn('usage: run_cmd.py', err.getvalue())

    def test_script_runs_from_the_command_line_and_names_no_process_killers(self):
        done = subprocess.run([sys.executable, str(SCRIPT), str(self.log), sys.executable, '-c', 'pass'])
        self.assertEqual(done.returncode, 0)
        self.assertEqual(self.log.read_text().splitlines()[-1], 'exit=0')
        source = SCRIPT.read_text()
        for banned in ('pk' + 'ill', 'kill' + 'all'):
            self.assertNotIn(banned, source)


if __name__ == '__main__':
    unittest.main()
