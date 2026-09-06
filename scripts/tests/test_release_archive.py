"""Incremental product retention must preserve cache bytes and symbol identity."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/release'))
spec = importlib.util.spec_from_file_location('release_archive', ROOT / 'scripts/release/release_archive.py')
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.products = self.root / 'products'
        self.app = self.products / 'Lungfish.app'
        self.info = self.app / 'Contents/Info.plist'
        self.info.parent.mkdir(parents=True)
        self.info.write_bytes(plistlib.dumps(dict(CFBundleExecutable='Lungfish', CFBundleIdentifier='org.example.fish',
                                                CFBundleShortVersionString='1.0', CFBundleVersion='1')))
        for executable, dsym in (('Lungfish', 'Lungfish.app.dSYM'), ('lungfish-cli', 'lungfish-cli.dSYM')):
            path = self.app / 'Contents/MacOS' / executable
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(b'native executable')
            path.chmod(0o755)
            dwarf = self.products / dsym / 'Contents/Resources/DWARF' / executable
            dwarf.parent.mkdir(parents=True)
            dwarf.write_bytes(b'native symbols')
        self.target = self.root / 'retained.xcarchive'
        self.calls = []
        self.mismatch = False
        def run(command, **kwargs):
            self.calls.append(command)
            if command[0] == '/usr/bin/ditto':
                shutil.copytree(command[1], command[2], symlinks=True)
                return subprocess.CompletedProcess(command, 0)
            self.assertEqual(command[:2], ['/usr/bin/dwarfdump', '--uuid'])
            uuid = '11111111-2222-3333-4444-555555555555'
            if self.mismatch and '/DWARF/' in command[-1]:
                uuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            return subprocess.CompletedProcess(command, 0, stdout=f'UUID: {uuid} (arm64) fixture\n')
        self.runner = patch.object(archive.subprocess, 'run', side_effect=run)
        self.runner.start()
        self.addCleanup(self.runner.stop)

    def test_retained_copy_stamping_does_not_change_compiler_products(self):
        original = self.info.read_bytes()
        archive.assemble(self.products, self.target)
        retained = self.target / 'Products/Applications/Lungfish.app/Contents/Info.plist'
        info = plistlib.loads(retained.read_bytes())
        info['CFBundleVersion'] = '99'
        info['CFBundleIdentifier'] = 'org.example.fish.preview'
        retained.write_bytes(plistlib.dumps(info))
        archive.finalize(self.target)
        metadata = plistlib.loads((self.target / 'Info.plist').read_bytes())
        self.assertEqual(metadata['ArchiveVersion'], 2)
        self.assertEqual(metadata['ApplicationProperties']['CFBundleVersion'], '99')
        self.assertEqual(metadata['ApplicationProperties']['CFBundleIdentifier'], 'org.example.fish.preview')
        self.assertEqual(self.info.read_bytes(), original)
        self.assertEqual(sum(call[0] == '/usr/bin/ditto' for call in self.calls), 3)

    def test_missing_cli_or_symbols_fails_before_archive_creation(self):
        for path in (self.app / 'Contents/MacOS/lungfish-cli',
                     self.products / 'lungfish-cli.dSYM/Contents/Resources/DWARF/lungfish-cli'):
            original = path.read_bytes()
            mode = path.stat().st_mode
            path.unlink()
            with self.assertRaises(archive.ArchiveError):
                archive.assemble(self.products, self.target)
            self.assertFalse(self.target.exists())
            path.write_bytes(original)
            path.chmod(mode)

    def test_mismatched_symbols_fail_before_any_copy(self):
        self.mismatch = True
        with self.assertRaisesRegex(archive.ArchiveError, 'UUID differs'):
            archive.assemble(self.products, self.target)
        self.assertFalse(self.target.exists())
        self.assertFalse(any(call[0] == '/usr/bin/ditto' for call in self.calls))

    def test_escaping_source_symlink_and_existing_destination_fail_closed(self):
        link = self.app / 'Contents/outside'
        link.symlink_to(self.root)
        with self.assertRaisesRegex(archive.ArchiveError, 'escaping'):
            archive.assemble(self.products, self.target)
        link.unlink()
        self.target.mkdir()
        sentinel = self.target / 'preserve'
        sentinel.write_text('existing')
        with self.assertRaisesRegex(archive.ArchiveError, 'must be new'):
            archive.assemble(self.products, self.target)
        self.assertEqual(sentinel.read_text(), 'existing')


if __name__ == '__main__': unittest.main()
