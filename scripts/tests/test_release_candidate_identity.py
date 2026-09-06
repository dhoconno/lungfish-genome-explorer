"""Candidate identity validation against fork contract and embedded CLI bytes."""
import base64
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

from scripts.release.release_contract import load_contract
from scripts.release.release_identity import fork_contract, identity_plist
from scripts.tests.test_debug_artifact import executable_bytes

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/release'))
SPEC = importlib.util.spec_from_file_location('candidate_identity_receipt', ROOT / 'scripts/release/release-candidate-receipt.py')
receipt = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receipt)


class CandidateIdentityTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        identity = dict(repository='example/genome', sparklePublicEdKey=base64.b64encode(b'f' * 32).decode(),
                        runtimeNamespace='org.example.genome', websiteURL='https://example.org',
                        documentationURL='https://example.org/docs', releaseHistoryURL='https://github.com/example/genome/releases')
        value = fork_contract(json.loads((ROOT / 'config/release-contract.json').read_text()), identity, 'Example Genome')
        path = self.root / 'contract.json'
        path.write_text(json.dumps(value))
        self.contract = load_contract(path)
        self.app = self.root / self.contract.channel('preview').appBundleFilename
        macos = self.app / 'Contents/MacOS'
        macos.mkdir(parents=True)
        self.info = {**identity_plist(self.contract, 'preview'), 'CFBundleExecutable': 'Lungfish',
                     'CFBundleVersion': '9', 'CFBundleShortVersionString': '1.0',
                     'SUFeedURL': f'https://github.com/example/genome/releases/download/{self.contract.channel("preview").sparkleRelease}/{self.contract.channel("preview").appcastFilename}',
                     'SUPublicEDKey': identity['sparklePublicEdKey'], 'SUVerifyUpdateBeforeExtraction': True}
        self.save_info()
        self.cli = macos / 'lungfish-cli'
        self.cli.write_bytes(executable_bytes(identity_plist(self.contract, 'preview')))
        self.cli.chmod(0o755)

    def save_info(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))

    def validate(self):
        with patch.object(receipt, 'load_contract', return_value=self.contract):
            return receipt._bundle_identity(self.app, 'preview')

    def test_fork_key_and_runtime_identity_are_bound(self):
        values, _ = self.validate()
        self.assertEqual(values['bundle']['publicKey'], self.contract.identity.sparklePublicEdKey)
        self.assertEqual(values['bundle']['runtimeIdentity'], identity_plist(self.contract, 'preview'))

    def test_native_cli_accepts_xcode_metadata_but_rejects_identity_and_updater_extras(self):
        embedded = {**identity_plist(self.contract, 'preview'), 'DTSDKName': 'macosx26.0',
                    'DTXcode': '2600', 'CFBundleExecutable': 'lungfish-cli',
                    'CFBundleSupportedPlatforms': ['MacOSX'], 'CFBundlePackageType': 'APPL'}
        self.cli.write_bytes(executable_bytes(embedded))
        self.validate()
        for key in ('SUFeedURL', 'SUPublicEDKey', 'LungfishUnexpectedIdentity'):
            self.cli.write_bytes(executable_bytes({**embedded, key: 'unexpected'}))
            with self.subTest(key=key), self.assertRaisesRegex(receipt.ReceiptError, 'CLI embedded'):
                self.validate()

    def test_wrong_feed_host_repository_or_key_cannot_create_candidate(self):
        original = self.info.copy()
        for key, value in [('SUFeedURL', 'https://evil.example/releases/download/sparkle-preview/appcast-preview.xml'),
                           ('SUFeedURL', 'https://github.com/other/genome/releases/download/sparkle-preview/appcast-preview.xml'),
                           ('SUPublicEDKey', base64.b64encode(b'x' * 32).decode()),
                           ('SUVerifyUpdateBeforeExtraction', False)]:
            self.info = {**original, key: value}
            self.save_info()
            with self.assertRaises(receipt.ReceiptError):
                self.validate()

    def test_missing_namespace_wrong_type_and_mismatched_cli_fail(self):
        original = self.info.copy()
        del self.info['LungfishRuntimeNamespace']
        self.save_info()
        with self.assertRaises(receipt.ReceiptError):
            self.validate()
        self.info = {**original, 'LungfishIdentitySchemaVersion': True}
        self.save_info()
        with self.assertRaises(receipt.ReceiptError):
            self.validate()
        self.info = original
        self.save_info()
        embedded = identity_plist(self.contract, 'preview')
        embedded['LungfishRuntimeNamespace'] = 'org.other.genome'
        self.cli.write_bytes(executable_bytes(embedded))
        with self.assertRaisesRegex(receipt.ReceiptError, 'CLI embedded'):
            self.validate()

    def test_missing_cli_identity_fails_before_any_signing(self):
        self.cli.write_bytes(b'old executable without identity')
        with self.assertRaisesRegex(receipt.ReceiptError, 'CLI embedded'):
            self.validate()


if __name__ == '__main__':
    unittest.main()
