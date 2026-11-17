"""Tests for scripts/release/notary_wait.sh, the wait for Apple's notary service after a setup red (E-RUN-69).

Each test runs the script with a stand-in for xcrun and one for sleep first on PATH, so no test reaches Apple or waits.
The stand-in sleep logs the seconds asked for, and each stand-in xcrun logs its arguments, one line a probe.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).parents[1] / 'release' / 'notary_wait.sh'
# The tools the script may take from /usr/bin. PATH holds only the test's folder and /bin, so no real xcrun is found.
TOOLS = ('perl', 'grep', 'head', 'cut', 'date')
FAIL_401 = 'echo "Error: HTTP status code: 401. Unable to authenticate."\nexit 69\n'
PASS = 'echo "Successfully received submission history."\nexit 0\n'


class NotaryWaitTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.bin, self.sleeps, self.probes = self.root / 'bin', self.root / 'sleeps.log', self.root / 'probes.log'
        self.bin.mkdir()
        for tool in TOOLS:
            found = shutil.which(tool)
            if found:
                (self.bin / tool).symlink_to(found)
        self.stub('sleep', 'echo "$1" >> "$SLEEP_LOG"\n')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + body)
        path.chmod(0o755)

    def xcrun(self, body):
        self.stub('xcrun', 'echo "$@" >> "$PROBE_LOG"\n' + body)

    def wait(self, *args, probe_s=None):
        env = {'PATH': '%s:/bin' % self.bin, 'HOME': str(self.root), 'SLEEP_LOG': str(self.sleeps),
               'PROBE_LOG': str(self.probes), 'FLAG': str(self.root / 'flag')}
        if probe_s is not None:
            env['NOTARY_WAIT_PROBE_S'] = str(probe_s)
        return subprocess.run(['/bin/bash', str(SCRIPT), *args], capture_output=True, text=True, env=env, timeout=120)

    def slept(self):
        return self.sleeps.read_text().split() if self.sleeps.exists() else []

    def probed(self):
        return self.probes.read_text().splitlines() if self.probes.exists() else []

    def assert_still_down(self, done):
        lines = done.stdout.splitlines()
        self.assertNotIn('NOTARY-OK', done.stdout)
        self.assertTrue(lines and lines[-1].startswith('NOTARY-STILL-DOWN '), done.stdout)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertEqual([line.split()[:2] for line in lines[:-1]], [['round', str(n)] for n in range(1, 6)])

    def test_a_probe_cut_off_by_its_alarm_is_never_ok(self):
        """The alarm kills the probe with SIGALRM and no output, which the copied script read as NOTARY-OK."""
        self.xcrun('kill -ALRM $$\n')
        self.assert_still_down(self.wait())
        self.assertEqual(len(self.probed()), 5)

    def test_a_probe_that_cannot_run_is_never_ok(self):
        self.assert_still_down(self.wait())
        self.assertEqual(self.slept(), ['600'] * 4)

    def test_a_hung_probe_ends_at_its_alarm_and_is_never_ok(self):
        self.xcrun('exec /bin/sleep 10\n')
        self.assert_still_down(self.wait(probe_s=1))

    def test_a_probe_that_exits_nonzero_with_no_error_words_is_never_ok(self):
        self.xcrun('echo "Unexpected reply."\nexit 3\n')
        self.assert_still_down(self.wait())

    def test_error_words_with_exit_0_are_never_ok(self):
        self.xcrun('echo "Error: HTTP status code: 401."\nexit 0\n')
        self.assert_still_down(self.wait())

    def test_a_401_waits_ten_minutes_a_round_and_the_wait_ends_within_55_minutes(self):
        self.xcrun(FAIL_401)
        done = self.wait()
        self.assert_still_down(done)
        self.assertIn('HTTP status code: 401', done.stdout.splitlines()[0])
        self.assertEqual((len(self.probed()), self.slept()), (5, ['600'] * 4))
        self.assertLessEqual(5 * 90 + sum(int(s) for s in self.slept()), 55 * 60)

    def test_a_pass_reports_ok_at_once(self):
        self.xcrun(PASS)
        done = self.wait()
        self.assertEqual((done.returncode, done.stdout.split()[0]), (0, 'NOTARY-OK'), done.stdout + done.stderr)
        self.assertEqual((len(self.probed()), self.slept()), (1, []))
        self.assertIn('release.py setup', done.stdout)

    def test_a_pass_after_a_401_round_reports_ok(self):
        self.xcrun('if [ -f "$FLAG" ]; then echo "Successfully received submission history."; exit 0; fi\n'
                   ': > "$FLAG"\n' + FAIL_401)
        done = self.wait()
        lines = done.stdout.splitlines()
        self.assertEqual((done.returncode, len(lines), lines[0].split()[:2], lines[1].split()[0]),
                         (0, 2, ['round', '1'], 'NOTARY-OK'), done.stdout + done.stderr)
        self.assertEqual(self.slept(), ['600'])

    def test_the_profile_and_keychain_reach_the_probe(self):
        self.xcrun(PASS)
        self.wait()
        self.wait('--profile', 'OtherNotary', '--keychain', '/k/notary.keychain-db')
        self.assertEqual(self.probed(), ['notarytool history --keychain-profile LungfishNotary',
                                         'notarytool history --keychain-profile OtherNotary --keychain /k/notary.keychain-db'])

    def test_bad_arguments_exit_2(self):
        self.xcrun(PASS)
        for extra in (['--profile'], ['--bogus', 'x'], ['--profile', '']):
            with self.subTest(extra):
                done = self.wait(*extra)
                self.assertEqual(done.returncode, 2, done.stdout)
                self.assertIn('usage: notary_wait.sh', done.stderr)
        self.assertEqual(self.probed(), [])

    def test_the_script_can_be_started_by_its_path(self):
        """lge-release.md:17 tells the release agent to start scripts/release/notary_wait.sh by its path."""
        self.assertTrue(os.access(SCRIPT, os.X_OK), 'chmod 755 %s' % SCRIPT)


if __name__ == '__main__':
    unittest.main()
