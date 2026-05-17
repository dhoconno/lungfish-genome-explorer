import unittest
from pathlib import Path


class ReleaseAppIconPackagingTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]
        self.script = (self.root / "scripts" / "release" / "build-notarized-dmg.sh").read_text()
        self.lines = self.script.splitlines()

    def test_release_script_installs_app_icon_metadata_and_resource_before_signing(self):
        self.assertIn('APP_ICON_SOURCE="${PROJECT_ROOT}/Sources/Lungfish/AppIcon.icns"', self.script)
        self.assertIn('APP_ICON_DEST="${APP_PATH}/Contents/Resources/AppIcon.icns"', self.script)
        self.assertIn('/usr/bin/install -m 644 "$APP_ICON_SOURCE" "$APP_ICON_DEST"', self.script)
        self.assertIn("Set :CFBundleIconFile AppIcon", self.script)
        self.assertIn("Set :CFBundleIconName AppIcon", self.script)

        install_index = self._line_index('/usr/bin/install -m 644 "$APP_ICON_SOURCE" "$APP_ICON_DEST"')
        codesign_index = self._line_index('/usr/bin/codesign --force --sign "$SIGNING_IDENTITY"')
        dmg_stage_index = self._line_index('/usr/bin/ditto "$APP_PATH" "${DMG_STAGING_DIR}/Lungfish.app"')

        self.assertLess(install_index, codesign_index)
        self.assertLess(install_index, dmg_stage_index)

    def _line_index(self, marker):
        for index, line in enumerate(self.lines):
            if marker in line:
                return index
        self.fail(f"missing line containing {marker!r}")


if __name__ == "__main__":
    unittest.main()
