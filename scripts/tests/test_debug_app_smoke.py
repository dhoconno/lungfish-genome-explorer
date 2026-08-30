import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SMOKE = ROOT / "scripts" / "smoke-test-debug-app.sh"


class DebugAppSmokeTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        self.app = self.root / "Lungfish Debug.app"
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        resources = self.app / "Contents" / "Resources"
        resources.mkdir(parents=True)
        bundle = resources / "Fixture.bundle"
        bundle.mkdir()
        (bundle / "resource.txt").write_text("fixture\n", encoding="utf-8")
        cli = self.app / "Contents" / "MacOS" / "lungfish-cli"
        cli.write_text(
            "#!/bin/bash\n"
            'test "${LUNGFISH_STORAGE_ROOT:-}" != ""\n'
            "echo debug-resource-smoke-ok\n",
            encoding="utf-8",
        )
        cli.chmod(0o755)
        self.info_plist = self.app / "Contents" / "Info.plist"
        self.write_plist({})

    def write_plist(self, additions):
        values = {
            "CFBundleDisplayName": "Lungfish Genome Explorer Debug",
            "CFBundleName": "Lungfish Debug",
            "CFBundleIdentifier": "com.lungfish.browser.debug",
            "LungfishReleaseChannel": "debug",
            **additions,
        }
        with self.info_plist.open("wb") as handle:
            plistlib.dump(values, handle)

    def run_smoke(self):
        return subprocess.run(
            ["bash", str(SMOKE), str(self.app)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "LC_ALL": "C"},
            check=False,
        )

    def test_relocates_debug_app_and_runs_non_ui_resource_probe(self):
        result = self.run_smoke()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Debug relocation/resource smoke passed", result.stdout)

    def test_rejects_any_sparkle_metadata(self):
        self.write_plist({"SUFeedURL": "https://example.invalid/appcast.xml"})

        result = self.run_smoke()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Sparkle", result.stderr)

    def test_rejects_app_without_runtime_resource_bundles(self):
        shutil.rmtree(self.app / "Contents" / "Resources" / "Fixture.bundle")

        result = self.run_smoke()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no runtime resource bundles", result.stderr)


if __name__ == "__main__":
    unittest.main()
