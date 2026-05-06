import unittest
from pathlib import Path


class SparkleReleasePackagingTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]
        self.package_swift = (self.root / "Package.swift").read_text()
        self.project = (self.root / "Lungfish.xcodeproj" / "project.pbxproj").read_text()
        self.release_script = (
            self.root / "scripts" / "release" / "build-notarized-dmg.sh"
        ).read_text()

    def test_app_target_links_sparkle_without_adding_it_to_lungfish_app_library(self):
        self.assertIn('url: "https://github.com/sparkle-project/Sparkle"', self.package_swift)
        self.assertIn('.product(name: "Sparkle", package: "Sparkle")', self.package_swift)
        self.assertNotIn(
            '"LungfishWorkflow",\n                .product(name: "Sparkle", package: "Sparkle")',
            self.package_swift,
            "Sparkle must stay out of LungfishApp so lungfish-cli does not inherit it.",
        )
        self.assertIn("/* Sparkle */", self.project)
        self.assertIn("productName = Sparkle;", self.project)

    def test_xcode_release_build_embeds_sparkle_info_plist_defaults(self):
        self.assertIn("INFOPLIST_KEY_SUFeedURL", self.project)
        self.assertIn("INFOPLIST_KEY_SUPublicEDKey", self.project)
        self.assertIn("INFOPLIST_KEY_SUVerifyUpdateBeforeExtraction = YES;", self.project)
        self.assertIn(
            "https://github.com/dhoconno/lungfish-genome-explorer/releases/download/sparkle-alpha/appcast-alpha.xml",
            self.project,
        )

    def test_release_script_can_publish_github_hosted_alpha_appcast(self):
        self.assertIn("--sparkle-generate-appcast", self.release_script)
        self.assertIn("--sparkle-ed-key-file", self.release_script)
        self.assertIn("--sparkle-appcast-dir", self.release_script)
        self.assertIn("--sparkle-publish-release", self.release_script)
        self.assertIn("--github-release-tag", self.release_script)
        self.assertIn("appcast-alpha.xml", self.release_script)
        self.assertIn("-o appcast-alpha.xml", self.release_script)
        self.assertIn('--ed-key-file "$SPARKLE_ED_KEY_FILE"', self.release_script)
        self.assertIn("--download-url-prefix", self.release_script)
        self.assertIn("gh release upload", self.release_script)
        self.assertIn('gh release upload "$GITHUB_RELEASE_TAG" "$DMG_PATH" --clobber', self.release_script)
        self.assertIn("Lungfish-${VERSION}-arm64.dmg.md", self.release_script)

    def test_release_script_creates_github_release_tags_at_current_commit(self):
        self.assertIn("target_commit=\"$(git rev-parse HEAD)\"", self.release_script)
        self.assertIn('--target "$target_commit"', self.release_script)

    def test_release_script_sets_incrementing_bundle_version_for_sparkle(self):
        self.assertIn("SPARKLE_BUILD_NUMBER", self.release_script)
        self.assertIn("git rev-list --count HEAD", self.release_script)
        self.assertIn('CURRENT_PROJECT_VERSION="$SPARKLE_BUILD_NUMBER"', self.release_script)

    def test_release_script_re_signs_sparkle_nested_code_before_outer_app(self):
        self.assertIn("sign_sparkle_framework", self.release_script)
        self.assertIn("Updater.app", self.release_script)
        self.assertIn("Downloader.xpc", self.release_script)
        self.assertIn("Installer.xpc", self.release_script)
        self.assertIn('sign_sparkle_framework "$APP_PATH/Contents/Frameworks/Sparkle.framework"', self.release_script)

        lines = self.release_script.splitlines()
        sparkle_sign_index = self._line_index('sign_sparkle_framework "$APP_PATH/Contents/Frameworks/Sparkle.framework"')
        outer_app_sign_index = self._line_index("# Outer app signing seals the bundle.")

        self.assertLess(sparkle_sign_index, outer_app_sign_index)

    def _line_index(self, marker):
        for index, line in enumerate(self.release_script.splitlines()):
            if marker in line:
                return index
        self.fail(f"missing line containing {marker!r}")


if __name__ == "__main__":
    unittest.main()
