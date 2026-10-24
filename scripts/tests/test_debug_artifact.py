"""Fast Debug checks using synthetic Mach-O bytes and fake process runners."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
from unittest.mock import patch

from scripts.release import debug_artifact
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


def place_executor(app, payload=b'\x7fELF stand-in executor\x00', **changes):
    """Contents/Resources/LinuxExecutor/x86_64 as linux_executor.place leaves it, with the manifest's eleven fields."""
    folder = app / 'Contents/Resources/LinuxExecutor/x86_64'
    folder.mkdir(parents=True)
    (folder / 'lungfish-executor').write_bytes(payload)
    (folder / 'lungfish-executor').chmod(0o755)
    manifest = {'schemaVersion': 1, 'relativePath': 'lungfish-executor', 'sha256': hashlib.sha256(payload).hexdigest(),
                'size': len(payload), 'lgeVersion': '1.2.3', 'lgeCommit': 'a' * 40,
                'targetTriple': 'x86_64-swift-linux-musl', 'toolchainID': 'swift-6.4.0-RELEASE',
                'toolchainSHA256': 'b' * 64, 'staticLinuxSDKID': 'swift-6.4.0-RELEASE_static-linux-0.1.0',
                'staticLinuxSDKSHA256': 'c' * 64, **changes}
    (folder / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return folder


def passing_runner(argv, **_options):
    return SimpleNamespace(returncode=0, stdout='1.2.3\n' if argv[1:] == ['--version'] else 'debug-resource-smoke-ok\n')


class DebugArtifactTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def fixture(self, selected, executor=True):
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
        if executor:
            place_executor(app)
        return app

    def test_debug_artifact_requires_executor_and_manifest(self):
        """QA-parity-4 condition 2: by default the app must hold exactly the executor and its manifest."""
        selected = contract()
        app = self.fixture(selected)
        folder = app / 'Contents/Resources/LinuxExecutor/x86_64'
        check_app(app, selected, runner=passing_runner)

        executor, manifest = (folder / 'lungfish-executor').read_bytes(), (folder / 'manifest.json').read_bytes()
        (folder / 'manifest.json').unlink()
        with self.assertRaisesRegex(DebugArtifactError, 'exactly lungfish-executor and manifest.json'):
            check_app(app, selected, runner=passing_runner)
        (folder / 'manifest.json').write_bytes(manifest)
        (folder / 'lungfish-executor').unlink()
        with self.assertRaisesRegex(DebugArtifactError, 'exactly lungfish-executor and manifest.json'):
            check_app(app, selected, runner=passing_runner)
        (self.root / 'elsewhere').write_bytes(executor)
        (folder / 'lungfish-executor').symlink_to(self.root / 'elsewhere')
        with self.assertRaisesRegex(DebugArtifactError, 'the executor is missing or not a regular file'):
            check_app(app, selected, runner=passing_runner)
        (folder / 'lungfish-executor').unlink()
        (folder / 'lungfish-executor').write_bytes(executor)
        (folder / 'placeholder').write_text('')
        with self.assertRaisesRegex(DebugArtifactError, 'exactly lungfish-executor and manifest.json'):
            check_app(app, selected, runner=passing_runner)
        (folder / 'placeholder').unlink()
        (folder.parent / 'aarch64').mkdir()
        with self.assertRaisesRegex(DebugArtifactError, 'exactly a x86_64 folder'):
            check_app(app, selected, runner=passing_runner)

        shutil.rmtree(app)
        app = self.fixture(selected, executor=False)
        with self.assertRaisesRegex(DebugArtifactError, 'lacks Contents/Resources/LinuxExecutor.*--without-linux-executor'):
            check_app(app, selected, runner=lambda *a, **kw: self.fail('no CLI probe runs for an app without the folder'))

    def test_debug_artifact_rejects_manifest_digest_mismatch(self):
        """QA-parity-4 condition 2: the manifest's SHA-256 and size must equal the file beside it."""
        selected = contract()
        for name, changes in (('sha256', {'sha256': '0' * 64}), ('size', {'size': 3}),
                              ('fields', {'schemaVersion': 2})):
            with self.subTest(name):
                shutil.rmtree(self.root / selected.profile('debug').appBundleFilename, ignore_errors=True)
                app = self.fixture(selected, executor=False)
                place_executor(app, **changes)
                message = 'fields are missing' if name == 'fields' else 'SHA-256 or size differs'
                with self.assertRaisesRegex(DebugArtifactError, 'Debug app Linux executor: .*' + message):
                    check_app(app, selected, runner=lambda *a, **kw: self.fail('no CLI probe runs after a mismatch'))
        shutil.rmtree(self.root / selected.profile('debug').appBundleFilename, ignore_errors=True)
        app = self.fixture(selected, executor=False)
        folder = place_executor(app)
        with (folder / 'lungfish-executor').open('ab') as handle:
            handle.write(b'\x00')
        with self.assertRaisesRegex(DebugArtifactError, 'SHA-256 or size differs'):
            check_app(app, selected, runner=passing_runner)

    def test_debug_artifact_without_executor_requires_folder_absent(self):
        """QA-parity-4 condition 3: --without-linux-executor accepts only an app with no LinuxExecutor folder."""
        selected = contract()
        app = self.fixture(selected, executor=False)
        check_app(app, selected, runner=passing_runner, linux_executor=False)
        resources = app / 'Contents/Resources'
        for name, make in (('a valid executor folder', lambda: place_executor(app)),
                           ('an empty folder', lambda: (resources / 'LinuxExecutor').mkdir()),
                           ('a symlink', lambda: (resources / 'LinuxExecutor').symlink_to(self.root / 'missing'))):
            with self.subTest(name):
                make()
                with self.assertRaisesRegex(DebugArtifactError,
                                            'built with --without-linux-executor holds Contents/Resources/LinuxExecutor'):
                    check_app(app, selected, runner=passing_runner, linux_executor=False)
                target = resources / 'LinuxExecutor'
                if target.is_symlink() or target.is_file():
                    target.unlink()
                else:
                    shutil.rmtree(target)
        # The command line must carry the flag into the check: no flag asks for the folder present, the flag for it absent.
        root = Path(__file__).resolve().parents[2]
        for flags, expected in (([], True), (['--without-linux-executor'], False)):
            with self.subTest(flags=flags), mock.patch.object(debug_artifact, 'check_app') as checked:
                self.assertEqual(debug_artifact.main(['check', '--root', str(root), '--app', str(app), *flags]), 0)
                checked.assert_called_once()
                self.assertEqual(checked.call_args.kwargs['linux_executor'], expected)

    def test_fast_checks_run_only_bounded_headless_cli_commands(self):
        selected = contract(fork=True)
        app = self.fixture(selected)
        calls = []
        def runner(argv, **options):
            calls.append((argv, options))
            self.assertEqual(Path(argv[0]), app / 'Contents/MacOS/lungfish-cli')
            self.assertLessEqual(options['timeout'], 45)
            self.assertNotEqual(options['env']['HOME'], os.environ.get('HOME'))
            for key in ('PACKAGE_RESOURCE_BUNDLE_PATH', 'PACKAGE_RESOURCE_BUNDLE_URL', 'DYLD_LIBRARY_PATH'):
                self.assertTrue(key not in options['env'], key)
            output = '1.2.3\n' if argv[1:] == ['--version'] else 'debug-resource-smoke-ok\n'
            return SimpleNamespace(returncode=0, stdout=output)
        with patch.dict(os.environ, {'PACKAGE_RESOURCE_BUNDLE_PATH': '/stale/resources',
                                     'PACKAGE_RESOURCE_BUNDLE_URL': '/stale/resources',
                                     'DYLD_LIBRARY_PATH': '/stale/libraries'}):
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

    def test_debug_build_selects_engine_matching_packaged_product_layout(self):
        import json
        import shutil
        import subprocess
        import sys
        source = Path(__file__).resolve().parents[2]
        root = self.root / 'checkout'
        for relative in ('scripts/build-app.sh', 'config/release-contract.json',
                         'Lungfish.xcodeproj/project.pbxproj'):
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / relative, target)
        release = root / 'scripts/release'
        release.mkdir()
        for name in ('release_contract.py', 'release_identity.py', 'release_xcode.py', 'debug_artifact.py', 'swiftpm_build.py',
                     'release_version.py'):
            shutil.copy2(source / 'scripts/release' / name, release / name)
        notes = root / 'docs/release-notes'
        notes.mkdir(parents=True)
        (notes / '2026.8.1.md').write_text('# Lungfish 2026.8.1\n')
        developer = self.root / 'Xcode.app/Contents/Developer'
        (developer / 'usr/bin').mkdir(parents=True)
        xcodebuild = developer / 'usr/bin/xcodebuild'
        xcodebuild.write_text('#!/bin/sh\nexit 0\n')
        xcodebuild.chmod(0o755)
        stub_dir = self.root / 'bin'
        stub_dir.mkdir()
        recorded = self.root / 'compiler-argv.json'
        sdk = self.root / 'SDK with spaces/MacOSX27.0.sdk'
        sdk.mkdir(parents=True)
        xcrun = stub_dir / 'xcrun'
        xcrun.write_text(f'#!{sys.executable}\nimport json,sys\n'
                         f'if sys.argv[1:] == ["--sdk", "macosx", "--show-sdk-path"]: print({str(sdk)!r}); sys.exit(0)\n'
                         f'open({str(recorded)!r}, "w").write(json.dumps(sys.argv[1:]))\n'
                         'sys.exit(79)\n')
        xcrun.chmod(0o755)
        # Without the stage release.py debug builds, the default stops before any compiler runs (QA-parity-4).
        result = subprocess.run(['bash', str(root / 'scripts/build-app.sh'), '--jobs', '3'],
                                env={**os.environ, 'PATH': str(stub_dir) + os.pathsep + os.environ['PATH'],
                                     'DEVELOPER_DIR': str(developer), 'LUNGFISH_RELEASE_PYTHON': sys.executable},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn('release.py debug', result.stderr)
        self.assertIn('--without-linux-executor', result.stderr)
        self.assertFalse(recorded.exists(), 'no compiler ran')
        result = subprocess.run(['bash', str(root / 'scripts/build-app.sh'), '--jobs', '3', '--without-linux-executor'],
                                env={**os.environ, 'PATH': str(stub_dir) + os.pathsep + os.environ['PATH'],
                                     'DEVELOPER_DIR': str(developer), 'LUNGFISH_RELEASE_PYTHON': sys.executable},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 79, result.stdout + result.stderr)
        argv = json.loads(recorded.read_text())
        self.assertEqual(argv[:2], ['swift', 'build'])
        self.assertIn('--build-system', argv)
        self.assertEqual(argv[argv.index('--build-system') + 1], 'swiftbuild')
        self.assertEqual(argv[argv.index('--jobs') + 1], '3')

        # A stale native product must never substitute for the selected engine.
        stale = root / '.build/arm64-apple-macosx/debug/Lungfish'
        stale.parent.mkdir(parents=True)
        stale.write_text('stale native product')
        selected_bin = root / 'custom products/Debug'
        xcrun.write_text(f'#!{sys.executable}\nimport json,sys\n'
                         f'if sys.argv[1:] == ["--sdk", "macosx", "--show-sdk-path"]: print({str(sdk)!r}); sys.exit(0)\n'
                         f'open({str(recorded)!r}, "w").write(json.dumps(sys.argv[1:]))\n'
                         f'print({str(selected_bin)!r})\n')
        result = subprocess.run(['bash', str(root / 'scripts/build-app.sh'), '--skip-build', '--jobs', '3',
                                 '--without-linux-executor'],
                                env={**os.environ, 'PATH': str(stub_dir) + os.pathsep + os.environ['PATH'],
                                     'DEVELOPER_DIR': str(developer), 'LUNGFISH_RELEASE_PYTHON': sys.executable},
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(selected_bin / 'Lungfish'), result.stdout + result.stderr)
        query = json.loads(recorded.read_text())
        self.assertEqual(query, [*argv, '--show-bin-path'])


if __name__ == '__main__':
    unittest.main()
