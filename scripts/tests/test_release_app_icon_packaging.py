import unittest
from pathlib import Path


class ReleaseAppIconPackagingTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]
        self.script = (
            self.root / "scripts" / "release" / "build-notarized-dmg.sh"
        ).read_text()
        self.lines = self.script.splitlines()

    def test_release_script_installs_app_icon_metadata_and_resource_before_signing(
        self,
    ):
        self.assertIn(
            'APP_ICON_SOURCE="${PROJECT_ROOT}/Sources/Lungfish/AppIcon.icns"',
            self.script,
        )
        self.assertIn(
            'APP_ICON_DEST="${APP_PATH}/Contents/Resources/AppIcon.icns"', self.script
        )
        self.assertIn(
            '/usr/bin/install -m 644 "$APP_ICON_SOURCE" "$APP_ICON_DEST"', self.script
        )
        self.assertIn("Set :CFBundleIconFile AppIcon", self.script)
        self.assertIn("Set :CFBundleIconName AppIcon", self.script)

        # Since 34548a699 signing and DMG staging happen in signing_pipeline.py,
        # which receives the unsigned candidate copied from the archived app.
        # The icon must be installed into the archived app before that copy.
        install_call_index = self._line_index("install_app_icon", exact=True)
        candidate_copy_index = self._line_index(
            '/usr/bin/ditto "$APP_PATH" "$RELEASE_APP_PATH"'
        )
        signing_input_index = self._line_index('--source-app "$RELEASE_APP_PATH"')

        self.assertLess(install_call_index, candidate_copy_index)
        self.assertLess(candidate_copy_index, signing_input_index)

    def _line_index(self, marker, exact=False):
        for index, line in enumerate(self.lines):
            if (line.strip() == marker) if exact else (marker in line):
                return index
        self.fail(f"missing line containing {marker!r}")


if __name__ == "__main__":
    unittest.main()
