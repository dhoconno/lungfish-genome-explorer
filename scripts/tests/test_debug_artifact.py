"""Fast Debug checks using synthetic Mach-O bytes and fake process runners."""
import os
from pathlib import Path
import plistlib
import struct
import tempfile
from types import SimpleNamespace
import unittest

from scripts.release.debug_artifact import DebugArtifactError, check_app, check_metadata, embedded_identity
from scripts.release.release_identity import identity_plist, apply_app_identity


def contract(fork=False):
    profile = SimpleNamespace(appBundleFilename='Example Debug.app', displayName='Example Debug',
                              bundleName='Example Debug', bundleIdentifier='org.example.genome.debug')
    identity = SimpleNamespace(runtimeNamespace='org.example.genome' if fork else None,
                               websiteURL='https://example.org', documentationURL='https://example.org/docs',
                               releaseHistoryURL='https://github.com/example/genome/releases')
    return SimpleNamespace(profile=lambda _: profile, identity=identity)


def executable_bytes(info):
    payload = plistlib.dumps(info)
    command_size = 72 + 80
    header = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 1, command_size, 0, 0)
    segment = struct.pack('<II16sQQQQiiII', 0x19, command_size, b'__TEXT', 0, len(payload),
                          0, len(payload), 5, 5, 1, 0)
    section = struct.pack('<16s16sQQIIIIIIII', b'__info_plist', b'__TEXT', 0, len(payload),
                          len(header) + command_size, 0, 0, 0, 0, 0, 0, 0)
    return header + segment + section + payload


class DebugArtifactTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def fixture(self, selected):
        app = self.root / selected.profile('debug').appBundleFilename
        executables = app / 'Contents/MacOS'
        executables.mkdir(parents=True)
        for name in ('Lungfish', 'lungfish-cli'):
            path = executables / name
            path.write_bytes(executable_bytes(identity_plist(selected, 'debug')))
            path.chmod(0o755)
        resources = app / 'Contents/Resources'
        for name in ('LungfishGenomeBrowser_LungfishWorkflow.bundle', 'LungfishGenomeBrowser_LungfishApp.bundle'):
            (resources / name).mkdir(parents=True)
        info = {**identity_plist(selected, 'debug'), 'CFBundleExecutable': 'Lungfish', 'CFBundleShortVersionString': '1.2.3'}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        help_info = resources / 'Lungfish.help/Contents/Info.plist'
        help_info.parent.mkdir(parents=True)
        help_info.write_bytes(plistlib.dumps({}))
        apply_app_identity(app, selected, 'debug')
        return app

    def test_fast_checks_run_only_bounded_headless_cli_commands(self):
        selected = contract(fork=True)
        app = self.fixture(selected)
        calls = []
        def runner(argv, **options):
            calls.append((argv, options))
            self.assertEqual(Path(argv[0]), app / 'Contents/MacOS/lungfish-cli')
            self.assertLessEqual(options['timeout'], 45)
            self.assertNotEqual(options['env']['HOME'], os.environ.get('HOME'))
            output = '1.2.3\n' if argv[1:] == ['--version'] else 'debug-resource-smoke-ok\n'
            return SimpleNamespace(returncode=0, stdout=output)
        check_app(app, selected, runner=runner)
        self.assertEqual([args[1:] for args, _ in calls], [['--version'], ['debug', 'resource-smoke']])
        self.assertFalse(any('relocat' in str(path) for path in self.root.iterdir()))

    def test_stale_cli_identity_is_rejected_before_execution(self):
        selected = contract(fork=True)
        app = self.fixture(selected)
        cli = app / 'Contents/MacOS/lungfish-cli'
        wrong = identity_plist(selected, 'debug')
        wrong['LungfishRuntimeNamespace'] = 'org.other.genome'
        cli.write_bytes(executable_bytes(wrong))
        with self.assertRaisesRegex(DebugArtifactError, 'embedded identity'):
            check_metadata(app, selected)

    def test_missing_resources_updater_and_fork_help_mismatch_fail(self):
        selected = contract(fork=True)
        app = self.fixture(selected)
        info = app / 'Contents/Info.plist'
        original = plistlib.loads(info.read_bytes())
        for changed, message in [({**original, 'SUFeedURL': 'https://example.org/feed'}, 'updater'),
                                 ({**original, 'CFBundleHelpBookName': 'Wrong'}, 'Help')]:
            info.write_bytes(plistlib.dumps(changed))
            with self.assertRaisesRegex(DebugArtifactError, message):
                check_metadata(app, selected)
        info.write_bytes(plistlib.dumps(original))
        (app / 'Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle').rmdir()
        with self.assertRaisesRegex(DebugArtifactError, 'resource bundle'):
            check_metadata(app, selected)

    def test_failed_cli_probe_does_not_pass(self):
        selected = contract()
        app = self.fixture(selected)
        with self.assertRaisesRegex(DebugArtifactError, 'CLI check failed'):
            check_app(app, selected, runner=lambda *a, **kw: SimpleNamespace(returncode=1, stdout='1.2.3\n'))

    def test_macho_reader_rejects_truncated_or_unbounded_sections(self):
        path = self.root / 'cli'
        good = executable_bytes({'example': 'value'})
        path.write_bytes(good)
        self.assertEqual(embedded_identity(path), {'example': 'value'})
        bad_size = bytearray(good)
        struct.pack_into('<Q', bad_size, 32 + 72 + 40, 65_537)
        for data in (good[:20], good[:80], good[:-5], bytes(bad_size)):
            path.write_bytes(data)
            with self.assertRaises(DebugArtifactError):
                embedded_identity(path)

    def test_build_options_reject_invalid_jobs_without_compiling(self):
        import subprocess
        root = Path(__file__).resolve().parents[2]
        for value in ('0', '-1', 'two', '1.5'):
            result = subprocess.run(['bash', str(root / 'scripts/build-app.sh'), '--jobs', value], capture_output=True, text=True)
            self.assertEqual(result.returncode, 64)
            self.assertIn('positive integer', result.stderr)


if __name__ == '__main__':
    unittest.main()
