"""Tests for micromamba checksum verification and update-tool-versions.sh retirement."""

import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class BundleNativeToolsChecksumTests(unittest.TestCase):
    def test_script_reads_manifest_checksum(self):
        text = (ROOT / "scripts/bundle-native-tools.sh").read_text()
        self.assertIn("third-party-tools-lock.json", text)
        self.assertIn("shasum -a 256", text)

    def test_update_tool_versions_script_is_gone(self):
        self.assertFalse((ROOT / "scripts/update-tool-versions.sh").exists())

    def test_manifest_and_tool_versions_agree(self):
        manifest = json.loads(
            (ROOT / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json").read_text()
        )
        tv = json.loads(
            (ROOT / "Sources/LungfishWorkflow/Resources/Tools/tool-versions.json").read_text()
        )
        mm = next(t for t in tv["tools"] if t["name"] == "micromamba")
        self.assertEqual(mm["version"], manifest["bootstrap"]["micromamba"]["version"])


class SmokeTestReleaseToolsVersionAgreementTests(unittest.TestCase):
    def test_smoke_script_checks_bootstrap_version_agreement(self):
        text = (ROOT / "scripts/smoke-test-release-tools.sh").read_text()
        self.assertIn("third-party-tools-lock.json", text)
        self.assertIn("bootstrap", text)


if __name__ == "__main__":
    unittest.main()
