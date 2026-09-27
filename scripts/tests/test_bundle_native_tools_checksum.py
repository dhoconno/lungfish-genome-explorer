"""Tests for micromamba checksum verification and update-tool-versions.sh retirement."""

import json
import pathlib
import subprocess
import tempfile
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

    def test_committed_sanitizer_reproduces_the_pinned_adhoc_checksum(self):
        manifest = json.loads(
            (ROOT / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json").read_text()
        )
        micromamba = manifest["bootstrap"]["micromamba"]
        with tempfile.TemporaryDirectory() as td:
            staged = pathlib.Path(td) / "micromamba"
            source_bytes = (ROOT / "Sources/LungfishWorkflow/Resources/Tools/micromamba").read_bytes()
            import hashlib
            self.assertEqual(
                hashlib.sha256(source_bytes).hexdigest(), micromamba["sha256"]["osx-arm64"]
            )
            staged.write_bytes(source_bytes)
            staged.chmod(0o755)
            subprocess.run(
                ["/bin/bash", str(ROOT / "scripts/sanitize-bundled-tools.sh"), "--adhoc-seal", td],
                check=True,
            )
            actual = hashlib.sha256(staged.read_bytes()).hexdigest()
        self.assertEqual(actual, micromamba["packagedSha256"]["osx-arm64-adhoc"])


class SmokeTestReleaseToolsVersionAgreementTests(unittest.TestCase):
    def test_smoke_script_checks_bootstrap_version_agreement(self):
        text = (ROOT / "scripts/smoke-test-release-tools.sh").read_text()
        self.assertIn("third-party-tools-lock.json", text)
        self.assertIn("bootstrap", text)


if __name__ == "__main__":
    unittest.main()
