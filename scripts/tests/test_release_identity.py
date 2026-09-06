import base64
import json
import plistlib
from pathlib import Path
import tempfile
import unittest

from scripts.release.release_identity import PublicIdentity, fork_contract, identity_plist


class ReleaseIdentityTests(unittest.TestCase):
    def identity(self, **changes):
        value = dict(repository="example/fish", sparklePublicEdKey=base64.b64encode(bytes(32)).decode(),
                     runtimeNamespace="org.example.fish", websiteURL="https://example.org/fish",
                     documentationURL="https://example.org/docs", releaseHistoryURL="https://github.com/example/fish/releases")
        value.update(changes)
        return value

    def test_rejects_invalid_key_namespace_and_credential_urls(self):
        for changes in ({"sparklePublicEdKey": "wrong"}, {"runtimeNamespace": "com.lungfish.other"},
                        {"websiteURL": "https://secret@example.org"}, {"repository": "../fish"},
                        {"releaseHistoryURL": "https://github.com/other/product/releases"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                PublicIdentity.parse(self.identity(**changes))

    def original(self):
        return json.loads((Path(__file__).resolve().parents[2] / 'config/release-contract.json').read_text())

    def load_payload(self, payload):
        from scripts.release.release_contract import load_contract
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'config/release-contract.json'
            path.parent.mkdir()
            path.write_text(json.dumps(payload))
            return load_contract(path)

    def test_fork_name_utf8_limit_reserves_channel_suffix(self):
        original = self.original()
        accepted = '🐟' * 48  # 192 UTF-8 bytes + eight-byte Preview suffix.
        self.assertEqual(len(fork_contract(original, self.identity(), accepted)['channels']['preview']['displayName'].encode()), 200)
        for name in (' Fish ', '${HOME}', '$(whoami)', '🐟' * 49, 'Fish\u0085', 'Fish\u200e'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                fork_contract(original, self.identity(), name)

    def test_namespace_limit_reserves_longest_channel_suffix_and_protects_upstream(self):
        namespace = 'org.' + 'a' * 168
        self.assertEqual(len(namespace), 172)
        PublicIdentity.parse(self.identity(runtimeNamespace=namespace))
        for invalid in (namespace + 'a', 'com.lungfish', 'org.lungfish.tool', 'org..fish'):
            with self.subTest(namespace=invalid), self.assertRaises(ValueError):
                PublicIdentity.parse(self.identity(runtimeNamespace=invalid))
        PublicIdentity.parse(self.identity(runtimeNamespace='org.lungfishfork.fish'))

    def test_product_urls_match_runtime_length_and_control_rules(self):
        prefix = 'https://example.org/'
        value = prefix + 'a' * (2048 - len(prefix))
        PublicIdentity.parse(self.identity(websiteURL=value))
        for url in (value + 'a', 'https://example.org/\u0085', 'https://example.org/\u200e', 'https://@example.org/'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                PublicIdentity.parse(self.identity(websiteURL=url))

    def test_loaded_contract_rejects_runtime_incompatible_fork_metadata(self):
        payload = fork_contract(self.original(), self.identity(), 'Fish')
        for field, invalid in [('displayName', '${HOME}'), ('bundleName', ' Fish '), ('bundleIdentifier', 'com.lungfish.browser')]:
            changed = json.loads(json.dumps(payload)); changed['channels']['stable'][field] = invalid
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.load_payload(changed)
        payload['channels']['preview']['legacyBridgeRelease'] = 'sparkle-alpha'
        payload['channels']['preview']['legacyBridgeAppcastFilename'] = 'bridge.xml'
        with self.assertRaises(ValueError):
            self.load_payload(payload)

    def test_upstream_without_fork_namespace_requires_runtime_exact_identity_tuple(self):
        for group, name in [('channels', 'stable'), ('channels', 'preview'), ('buildProfiles', 'debug')]:
            for field in ('displayName', 'bundleName', 'bundleIdentifier'):
                payload = self.original(); payload[group][name][field] = 'org.example.changed' if field == 'bundleIdentifier' else 'Changed Name'
                with self.subTest(channel=name, field=field), self.assertRaises(ValueError):
                    self.load_payload(payload)

    def test_app_restamp_removes_stale_fork_namespace_for_upstream(self):
        from scripts.release.release_identity import apply_app_identity
        contract = self.load_payload(self.original())
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / 'Lungfish.app'
            (app / 'Contents').mkdir(parents=True)
            info = app / 'Contents/Info.plist'
            info.write_bytes(plistlib.dumps({'LungfishIdentitySchemaVersion': 1,
                                             'LungfishRuntimeNamespace': 'org.example.old',
                                             'CFBundleVersion': 'unchanged'}))
            apply_app_identity(app, contract, 'stable')
            metadata = plistlib.loads(info.read_bytes())
            self.assertNotIn('LungfishIdentitySchemaVersion', metadata)
            self.assertNotIn('LungfishRuntimeNamespace', metadata)
            self.assertEqual(metadata['CFBundleVersion'], 'unchanged')
            self.assertEqual(metadata['CFBundleIdentifier'], 'com.lungfish.browser')

    def test_fork_config_has_unique_channels_and_no_upstream_bridge(self):
        root = Path(__file__).resolve().parents[2]
        original = json.loads((root / "config/release-contract.json").read_text())
        result = fork_contract(original, self.identity(), "Example Fish")
        self.assertEqual(original["channels"]["preview"]["bundleIdentifier"], "com.lungfish.browser.preview")
        self.assertEqual(result["channels"]["stable"]["bundleIdentifier"], "org.example.fish")
        self.assertEqual(result["channels"]["preview"]["bundleIdentifier"], "org.example.fish.preview")
        self.assertEqual(result["buildProfiles"]["debug"]["bundleIdentifier"], "org.example.fish.debug")
        self.assertEqual(result["channels"]["preview"]["legacyBridgeRelease"], "")
        self.assertEqual(result["channels"]["preview"]["displayName"], "Example Fish Preview")

    def test_compact_cli_identity_has_no_version_or_secret_fields(self):
        from scripts.release.release_contract import load_contract
        root = Path(__file__).resolve().parents[2]
        original = json.loads((root / "config/release-contract.json").read_text())
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "contract.json"
            path.write_text(json.dumps(fork_contract(original, self.identity(), "Example Fish")))
            contract = load_contract(path)
            metadata = identity_plist(contract, "preview")
        self.assertEqual(metadata["LungfishIdentitySchemaVersion"], 1)
        self.assertEqual(metadata["LungfishRuntimeNamespace"], "org.example.fish")
        self.assertEqual(metadata["LungfishReleaseChannel"], "preview")
        self.assertNotIn("CFBundleVersion", metadata)
        self.assertNotIn("SUFeedURL", metadata)


if __name__ == "__main__":
    unittest.main()
