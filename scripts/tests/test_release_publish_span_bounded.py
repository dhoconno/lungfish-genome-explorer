"""The steps after signing never hold a publish for hours (RELEASE-SMOKE-DOCUMENTS-PROMPT, continuation RELPROMPT-2).

On 2026-11-05 the publish of Preview 2026.11.1 spent 18,003 seconds inside build-notarized-dmg.sh. The signing transaction
ended at 20:54:53, the Sparkle gates ran again at 01:52:09, and the wait ended 0.6 seconds after a click answered a macOS
privacy prompt for the Documents folder. The signed-app smoke was not the wait (3.8 seconds). The retained system log cannot
name the process that was blocked, so every step after signing that reads the release folder or the network is bounded
and a step that runs out of time says what to do. All tests are offline and run on fakes.
"""
import importlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from scripts.release.release_profiles import ReleaseProfile

ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / 'scripts/release/build-notarized-dmg.sh'
BOUNDED_PROCESS = ROOT / 'scripts/release/bounded_process.py'
SPAN_FUNCTIONS = (
    'verify_versioned_release_identity', 'publish_github_release_dmg', 'verify_uploaded_asset_digest',
    'publish_mutable_asset_if_changed', 'generate_sparkle_appcast', 'verify_file_matches_remote_asset',
)
GUARDED = ('/usr/bin/shasum', '/bin/cp -p', '/usr/libexec/PlistBuddy', 'git ls-remote', '/usr/bin/install -m 644 "$notes_source"')
BOUNDED = ('bounded_local', 'bounded_network')
PROMPT_WORDS = (
    'privacy prompt', 'remote or scripted click', 'run the publish at the Mac',
    'System Settings', 'Privacy and Security', 'Files and Folders',
)


def function_body(text, name):
    start = text.index(name + '() {')
    return text[start:text.index('\n}\n', start)]


class BuilderSpanIsBoundedTests(unittest.TestCase):
    def test_every_step_after_signing_that_reads_the_release_folder_or_the_network_is_bounded(self):
        text = BUILDER.read_text()
        spans = {name: function_body(text, name) for name in SPAN_FUNCTIONS}
        spans['main flow after the signing pipeline'] = text[text.index('signing_pipeline.py" "${signing_args[@]}"'):]
        offenders = []
        for where, body in spans.items():
            for line in body.splitlines():
                if any(token in line for token in GUARDED) and not any(name in line for name in BOUNDED):
                    offenders.append(f'{where}: {line.strip()}')
        self.assertEqual([], offenders, 'these steps run with no time limit, so a privacy prompt or a stuck network '
                         'call can hold the publish for hours')
        self.assertIn('--local-files', text, 'bounded_local must ask for the words about the privacy prompt')
        names = re.findall(r'bounded_(?:local|network) ([a-z0-9-]+) ', text)
        repeated = sorted({name for name in names if names.count(name) > 1})
        self.assertEqual(len(names), len(set(names)), f'every bounded step has its own name, so a timeout says which step it was (repeated: {repeated})')


class BoundedProcessWordsTests(unittest.TestCase):
    def run_bounded(self, *arguments, timeout=60):
        start = time.monotonic()
        result = subprocess.run([sys.executable, str(BOUNDED_PROCESS), *arguments], capture_output=True, text=True, timeout=timeout)
        return result, time.monotonic() - start

    def test_a_local_step_that_never_ends_fails_in_words_that_name_the_prompt(self):
        result, seconds = self.run_bounded('--timeout', '2', '--phase', 'plist-read', '--local-files', '--', 'sleep', '60')
        self.assertLess(seconds, 30, 'the step must be stopped at its limit')
        self.assertEqual(124, result.returncode, result.stderr)
        for words in ('plist-read', 'timed out after 2 seconds') + PROMPT_WORDS:
            self.assertIn(words, result.stderr)

    def test_a_step_that_ends_in_time_says_nothing_about_the_prompt(self):
        result, _ = self.run_bounded('--timeout', '20', '--phase', 'plist-read', '--local-files', '--public-stdout', '--', 'echo', 'ok')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('ok\n', result.stdout)
        self.assertNotIn('privacy prompt', result.stderr)

    def test_a_network_step_that_never_ends_names_the_step_and_not_the_prompt(self):
        result, _ = self.run_bounded('--timeout', '2', '--phase', 'git-ls-remote', '--', 'sleep', '60')
        self.assertEqual(124, result.returncode, result.stderr)
        self.assertIn('git-ls-remote timed out after 2 seconds', result.stderr)
        self.assertNotIn('privacy prompt', result.stderr)

    def test_a_step_whose_pipes_outlive_the_kill_still_fails_in_the_words(self):
        # A descendant that left the process group keeps the pipes open after the kill, as a process stuck on a prompt would.
        holder = shlex.quote(sys.executable) + ' -I -c "import os,time; os.setsid(); time.sleep(10)" & sleep 10'
        result, seconds = self.run_bounded('--timeout', '2', '--phase', 'plist-read', '--local-files', '--', '/bin/sh', '-c', holder)
        self.assertLess(seconds, 30, 'the step must be stopped at its limit')
        self.assertEqual(124, result.returncode, result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        for words in ('plist-read timed out after 2 seconds',) + PROMPT_WORDS:
            self.assertIn(words, result.stderr)

    def test_a_local_step_that_fails_shows_its_own_error(self):
        arguments = ('--timeout', '20', '--phase', 'dmg-copy', '--public-stdout')
        command = ('--', '/bin/sh', '-c', 'echo no space left on device >&2; exit 1')
        result, _ = self.run_bounded(*arguments, '--local-files', *command)
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertIn('no space left on device', result.stderr, 'a failing local step keeps the error it printed')
        result, _ = self.run_bounded(*arguments, *command)
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertNotIn('no space left on device', result.stderr, 'a step that may carry a credential forwards nothing')


class SmokeWordsReachTheConsoleTests(unittest.TestCase):
    """F2 of RELPROMPT: the smoke's own words reach the console on the signing pipeline's route."""

    def setUp(self):
        self.m = importlib.import_module('scripts.release.signing_pipeline')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / 'unsigned' / 'Example.app'
        (self.source / 'Contents/MacOS').mkdir(parents=True)
        (self.source / 'Contents/MacOS/lungfish-cli').write_bytes(b'fake cli')
        (self.source / 'Contents/Info.plist').write_bytes(b'fake info')
        self.receipt = self.root / 'candidate.json'
        self.receipt.write_text('{}')
        self.entitlements = self.root / 'entitlements'
        self.entitlements.write_text('fake')
        self.smoke = self.root / 'smoke-test-release-tools.sh'
        self.smoke.write_text('#!/bin/bash\n')
        self.profile = ReleaseProfile('example/product', 'Developer ID Application: Example (TEAM123456)', 'TEAM123456',
                                      'notary', signing_keychain='/fake/keychain', certificate_sha1='A' * 40, schema_version=2)

    def run_tool(self, argv, **kwargs):
        name = Path(argv[0]).name
        if name == 'ditto':
            shutil.copytree(argv[-2], argv[-1])
        elif name == 'codesign' and '--display' in argv:
            return subprocess.CompletedProcess(argv, 0, '', 'TeamIdentifier=TEAM123456\n')
        elif name == 'file':
            return subprocess.CompletedProcess(argv, 0, 'Mach-O 64-bit executable', '')
        if argv[:2] == ['/bin/bash', str(self.smoke)]:
            stderr = ('PASS portability\nPASS micromamba\nFAIL lungfish-cli-version timed out after 60 seconds\n'
                      'macOS may be showing a privacy prompt that a remote or scripted click cannot answer. '
                      'To go on, run the publish at the Mac, or answer it in System Settings, Privacy and Security, Files and Folders.\n')
            return subprocess.CompletedProcess(argv, 124, '', stderr)
        return subprocess.CompletedProcess(argv, 0, '', '')

    def test_a_smoke_that_runs_out_of_time_puts_its_last_lines_in_the_one_message(self):
        with self.assertRaises(self.m.SigningError) as raised:
            self.m.sign_and_notarize(
                self.source, self.receipt, self.root / 'signed/Example.app', self.root / 'Example.dmg', self.root / 'transaction',
                self.profile, entitlements=self.entitlements, volume_name='Example', public_key='public-key',
                run=self.run_tool, notary=lambda *a, **kw: self.fail('a failed smoke must not reach notarization'),
                smoke_script=self.smoke)
        message = str(raised.exception)
        for words in ('signed-app-tool-smoke', 'lungfish-cli-version timed out after 60 seconds') + PROMPT_WORDS:
            self.assertIn(words, message)
        self.assertNotIn('\n', message, 'the console message is one line')


if __name__ == '__main__':
    unittest.main()
