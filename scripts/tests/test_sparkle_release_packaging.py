import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class SparkleReleasePackagingTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]
        self.package_swift = (self.root / "Package.swift").read_text()
        self.project = (
            self.root / "Lungfish.xcodeproj" / "project.pbxproj"
        ).read_text()
        self.info_plist = (self.root / "Lungfish-Info.plist").read_text()
        self.release_script = (
            self.root / "scripts" / "release" / "build-notarized-dmg.sh"
        ).read_text()
        self.release_script_path = (
            self.root / "scripts" / "release" / "build-notarized-dmg.sh"
        )
        self.release_contract = json.loads(
            (self.root / "config" / "release-contract.json").read_text()
        )

    def test_app_target_links_sparkle_without_adding_it_to_lungfish_app_library(self):
        self.assertIn(
            'url: "https://github.com/sparkle-project/Sparkle"', self.package_swift
        )
        self.assertIn(
            '.product(name: "Sparkle", package: "Sparkle")', self.package_swift
        )
        self.assertNotIn(
            '"LungfishWorkflow",\n                .product(name: "Sparkle", package: "Sparkle")',
            self.package_swift,
            "Sparkle must stay out of LungfishApp so lungfish-cli does not inherit it.",
        )
        self.assertIn("/* Sparkle */", self.project)
        self.assertIn("productName = Sparkle;", self.project)

    def test_xcode_release_build_uses_shared_sparkle_info_plist_defaults(self):
        self.assertIn('INFOPLIST_FILE = "Lungfish-Info.plist";', self.project)
        self.assertIn("LUNGFISH_SPARKLE_PUBLIC_ED_KEY", self.project)
        self.assertIn("<key>SUFeedURL</key>", self.info_plist)
        self.assertIn("<key>SUPublicEDKey</key>", self.info_plist)
        self.assertIn("<key>SUVerifyUpdateBeforeExtraction</key>", self.info_plist)
        self.assertIn("<true/>", self.info_plist)
        self.assertIn(
            "https://github.com/dhoconno/lungfish-genome-explorer/releases/download/sparkle-beta/appcast-beta.xml",
            self.info_plist,
        )

    def test_release_script_can_publish_github_hosted_beta_appcast(self):
        self.assertIn("--sparkle-generate-appcast", self.release_script)
        self.assertIn("--sparkle-ed-key-file", self.release_script)
        self.assertIn("--sparkle-appcast-dir", self.release_script)
        self.assertIn("--sparkle-appcast-filename", self.release_script)
        self.assertIn("--sparkle-publish-release", self.release_script)
        self.assertIn("--github-release-tag", self.release_script)
        self.assertIn('-o "$SPARKLE_APPCAST_PATH"', self.release_script)
        self.assertIn('--ed-key-file "$SPARKLE_ED_KEY_FILE"', self.release_script)
        self.assertIn("--download-url-prefix", self.release_script)
        self.assertIn("--release-notes-url-prefix", self.release_script)
        self.assertIn("release_notes_url_prefix=", self.release_script)
        self.assertIn(
            'download_url_prefix="${download_url_prefix}/"', self.release_script
        )
        self.assertIn("github_cli release upload", self.release_script)
        self.assertIn('release create "$GITHUB_RELEASE_TAG"', self.release_script)
        self.assertIn('"$DMG_PATH"', self.release_script)
        self.assertIn("Lungfish-${VERSION}-arm64.md", self.release_script)
        self.assertIn("docs/release-notes/${VERSION}.md", self.release_script)
        self.assertNotIn("docs/release-notes/v${VERSION}.md", self.release_script)

    def test_channel_defaults_select_the_matching_feed_container(self):
        for channel in ("preview", "stable"):
            with self.subTest(channel=channel):
                result = self._run_builder("--describe-channel", channel)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    json.loads(result.stdout),
                    self.release_contract["channels"][channel],
                )

    def test_release_script_help_describes_the_contract_selected_channel(self):
        cases = (
            ("preview", ("--help", "--channel", "preview")),
            ("stable", ("--channel", "stable", "--help")),
        )
        for channel, arguments in cases:
            with self.subTest(channel=channel):
                result = self._run_builder(*arguments)

                self.assertEqual(result.returncode, 0, result.stderr)
                described = json.loads(result.stdout.rstrip().splitlines()[-1])
                self.assertEqual(
                    described,
                    self.release_contract["channels"][channel],
                )
                self.assertIn(
                    f"Contract-selected defaults for {channel}:", result.stdout
                )
                self.assertNotIn("default: appcast-beta.xml", result.stdout)
                self.assertNotIn("default: appcast-alpha.xml", result.stdout)

    def test_release_script_rejects_invalid_channels_behaviorally(self):
        result = self._run_builder("--describe-channel", "nightly")

        self.assertEqual(result.returncode, 64)
        self.assertIn("invalid --channel", result.stderr)

    def test_stable_channel_rejects_preview_only_flags_behaviorally(self):
        cases = (
            (
                "--sparkle-bridge-publish-release",
                "sparkle-alpha",
                "legacy preview-feed bridge",
            ),
            (
                "--sparkle-bridge-appcast-filename",
                "appcast-custom.xml",
                "legacy preview-feed bridge",
            ),
            ("--prune-prereleases", None, "preview-release pruning"),
        )
        for flag, value, expected_error in cases:
            with self.subTest(flag=flag):
                arguments = [
                    "--signing-identity",
                    "dummy",
                    "--team-id",
                    "TEAMID",
                    "--notary-profile",
                    "dummy",
                    "--channel",
                    "stable",
                    flag,
                ]
                if value is not None:
                    arguments.append(value)
                result = self._run_builder(*arguments)

                self.assertEqual(result.returncode, 64)
                self.assertIn(expected_error, result.stderr)

    def test_xcode_and_swift_package_pin_the_same_sparkle_version(self):
        self.assertIn('exact: "2.9.6"', self.package_swift)
        self.assertIn("version = 2.9.6;", self.project)

    def test_release_script_rejects_noncanonical_marketing_versions(self):
        self.assertIn(
            "invalid release version; expected YYYY.M.PATCH", self.release_script
        )

    def test_release_script_calver_guard_is_behavioral(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            script = root / "scripts" / "release" / "build-notarized-dmg.sh"
            version_file = root / "Sources" / "LungfishCore" / "AppVersion.swift"
            manifest_file = (
                root
                / "Sources"
                / "LungfishWorkflow"
                / "Resources"
                / "ManagedTools"
                / "third-party-tools-lock.json"
            )
            script.parent.mkdir(parents=True)
            version_file.parent.mkdir(parents=True)
            manifest_file.parent.mkdir(parents=True)
            shutil.copy2(
                self.root / "scripts" / "release" / "build-notarized-dmg.sh", script
            )
            shutil.copy2(
                self.root / "scripts" / "release" / "release_contract.py",
                script.parent / "release_contract.py",
            )
            shutil.copy2(
                self.root / "scripts" / "release" / "release_xcode.py",
                script.parent / "release_xcode.py",
            )
            contract = root / "config" / "release-contract.json"
            contract.parent.mkdir(parents=True)
            shutil.copy2(self.root / "config" / "release-contract.json", contract)
            manifest_file.write_text('{"dependencySet":"2026.2"}\n', encoding="utf-8")

            def run(version, tag=None, notes_text=None, channel="preview"):
                version_file.write_text(
                    f'public enum LungfishAppVersion {{ public static let short = "{version}" }}\n',
                    encoding="utf-8",
                )
                notes = root / "docs" / "release-notes" / f"{version}.md"
                notes.parent.mkdir(parents=True, exist_ok=True)
                notes.write_text(
                    notes_text
                    or (
                        f"# Lungfish {version}\n\n"
                        "Channel: Preview\n\n"
                        "Previous versioned release: v0.5.0-beta29\n\n"
                        "Stable baseline: None (bootstrap aggregation baseline: v0.5.0-beta29)\n\n"
                        "Dependency set: 2026.2\n\n"
                        "## Dependency versions\n"
                    ),
                    encoding="utf-8",
                )
                environment = os.environ.copy()
                environment.pop("LUNGFISH_SPARKLE_PUBLIC_ED_KEY", None)
                command = [
                    "bash",
                    str(script),
                    "--signing-identity",
                    "dummy",
                    "--team-id",
                    "TEAMID",
                    "--notary-profile",
                    "dummy",
                    "--channel",
                    channel,
                ]
                if tag is not None:
                    command.extend(["--github-release-tag", tag])
                return subprocess.run(
                    command,
                    text=True,
                    capture_output=True,
                    env=environment,
                    check=False,
                )

            valid = run("2026.8.1", "v2026.8.1")
            self.assertIn("missing Sparkle public EdDSA key", valid.stderr)
            self.assertNotIn("invalid release version", valid.stderr)
            for invalid in ("2026.08.1", "2026.8.1-beta1"):
                self.assertIn(
                    "invalid release version", run(invalid, f"v{invalid}").stderr
                )
            self.assertIn(
                "GitHub release tag must be v2026.8.1",
                run("2026.8.1", "v2026.8.2").stderr,
            )
            missing_audit = run("2026.8.1", "v2026.8.1", "# Lungfish 2026.8.1\n")
            self.assertIn(
                "release notes are missing required audit field", missing_audit.stderr
            )
            inferred_tag_missing_audit = run(
                "2026.8.1", notes_text="# Lungfish 2026.8.1\n"
            )
            self.assertIn(
                "release notes are missing required audit field",
                inferred_tag_missing_audit.stderr,
            )

    def test_release_script_rejects_existing_versioned_release_by_default(self):
        self.assertIn(
            "versioned GitHub release already exists; refusing to overwrite",
            self.release_script,
        )
        self.assertNotIn('gh release edit "$GITHUB_RELEASE_TAG"', self.release_script)

    def test_release_script_requires_detailed_notes_before_building(self):
        self.assertIn(
            "detailed release notes must exist before building", self.release_script
        )
        self.assertNotIn('preview release.")', self.release_script)

    def test_release_script_requires_verified_identity_for_explicit_recovery(self):
        self.assertIn("--recover-existing-release", self.release_script)
        self.assertIn("RECOVER_EXISTING_RELEASE", self.release_script)
        self.assertIn("refs/tags/${GITHUB_RELEASE_TAG}^{}", self.release_script)
        self.assertIn("targetCommitish", self.release_script)
        self.assertIn("isPrerelease", self.release_script)
        self.assertIn(
            "existing GitHub release channel does not match --channel",
            self.release_script,
        )
        self.assertIn("isDraft", self.release_script)
        self.assertIn("release tag does not point to HEAD", self.release_script)
        self.assertIn("existing release DMG digest differs", self.release_script)
        self.assertGreaterEqual(
            self.release_script.count("verify_versioned_release_identity"), 3
        )

    def test_release_script_can_prune_old_prerelease_releases_without_git_tags(self):
        self.assertIn("--prune-prereleases", self.release_script)
        self.assertIn("--prune-prereleases-keep", self.release_script)
        self.assertIn("prune-github-prereleases.py", self.release_script)
        self.assertIn('"$PRERELEASE_PRUNE_SCRIPT"', self.release_script)
        self.assertIn("--current-tag", self.release_script)
        self.assertIn("--apply", self.release_script)
        self.assertNotIn("--cleanup-tag", self.release_script)
        self.assertIn("prerelease_prune_report_path=", self.release_script)
        self.assertIn("prerelease_prune_enabled=", self.release_script)

    def test_release_script_can_publish_legacy_alpha_appcast_filename(self):
        result = self._run_builder("--describe-channel", "preview")

        self.assertEqual(result.returncode, 0, result.stderr)
        described = json.loads(result.stdout)
        self.assertEqual(described["legacyBridgeRelease"], "sparkle-alpha")
        self.assertEqual(described["legacyBridgeAppcastFilename"], "appcast-alpha.xml")

    def test_release_script_can_publish_legacy_bridge_feed_without_changing_primary_feed(
        self,
    ):
        self.assertIn("--sparkle-bridge-publish-release", self.release_script)
        self.assertIn("--sparkle-bridge-appcast-filename", self.release_script)
        self.assertIn('SPARKLE_BRIDGE_PUBLISH_RELEASE="$2"', self.release_script)
        self.assertIn('SPARKLE_BRIDGE_APPCAST_FILENAME="$2"', self.release_script)
        self.assertIn(
            'local bridge_appcast_path="${SPARKLE_APPCAST_DIR}/${SPARKLE_BRIDGE_APPCAST_FILENAME}"',
            self.release_script,
        )
        self.assertIn(
            '/bin/cp -p "$SPARKLE_APPCAST_PATH" "$bridge_appcast_path"',
            self.release_script,
        )
        self.assertIn(
            'publish_mutable_asset_if_changed "$SPARKLE_BRIDGE_PUBLISH_RELEASE" "$bridge_appcast_path"',
            self.release_script,
        )
        self.assertIn(
            'github_cli release upload "$release_tag" "$local_path" --clobber',
            self.release_script,
        )

    def test_release_script_stamps_channel_specific_bundle_identity_before_signing_and_dmg_staging(
        self,
    ):
        for expected in (
            "plutil -replace CFBundleDisplayName",
            "plutil -replace CFBundleName",
            "plutil -replace LungfishReleaseChannel",
        ):
            self.assertIn(expected, self.release_script)

        configure_index = self._line_index(
            'configure_sparkle_info_plist "$APP_PATH/Contents/Info.plist"'
        )
        outer_sign_index = self._line_index("# Outer app signing seals the bundle.")
        dmg_staging_index = self._line_index(
            '"${DMG_STAGING_DIR}/${APP_BUNDLE_FILENAME}"'
        )
        self.assertLess(configure_index, outer_sign_index)
        self.assertLess(configure_index, dmg_staging_index)

        self.assertIn(
            'APP_PATH="${ARCHIVE_PATH}/Products/Applications/Lungfish.app"',
            self.release_script,
        )
        self.assertIn(
            'RELEASE_APP_PATH="${RELEASE_DIR}/${APP_BUNDLE_FILENAME}"',
            self.release_script,
        )
        self.assertIn(
            '"${DMG_STAGING_DIR}/${APP_BUNDLE_FILENAME}"', self.release_script
        )
        self.assertIn('-volname "$DMG_VOLUME_NAME"', self.release_script)

        for channel in ("preview", "stable"):
            with self.subTest(channel=channel):
                result = self._run_builder("--describe-channel", channel)
                self.assertEqual(result.returncode, 0, result.stderr)
                described = json.loads(result.stdout)
                expected = self.release_contract["channels"][channel]
                self.assertEqual(
                    described["appBundleFilename"], expected["appBundleFilename"]
                )
                self.assertEqual(described["displayName"], expected["displayName"])
                self.assertEqual(described["bundleName"], expected["bundleName"])
                self.assertEqual(described["dmgVolumeName"], expected["dmgVolumeName"])

    def test_release_script_creates_github_release_tags_at_current_commit(self):
        self.assertIn('target_commit="$(git rev-parse HEAD)"', self.release_script)
        self.assertIn('--target "$target_commit"', self.release_script)

    def test_release_script_sets_incrementing_bundle_version_for_sparkle(self):
        self.assertIn("SPARKLE_BUILD_NUMBER", self.release_script)
        self.assertIn("git rev-list --count HEAD", self.release_script)
        self.assertIn(
            'CURRENT_PROJECT_VERSION="$SPARKLE_BUILD_NUMBER"', self.release_script
        )

    def test_release_script_re_signs_sparkle_nested_code_before_outer_app(self):
        self.assertIn("sign_sparkle_framework", self.release_script)
        self.assertIn("Updater.app", self.release_script)
        self.assertIn("Downloader.xpc", self.release_script)
        self.assertIn("Installer.xpc", self.release_script)
        self.assertIn(
            'sign_sparkle_framework "$APP_PATH/Contents/Frameworks/Sparkle.framework"',
            self.release_script,
        )

        lines = self.release_script.splitlines()
        sparkle_sign_index = self._line_index(
            'sign_sparkle_framework "$APP_PATH/Contents/Frameworks/Sparkle.framework"'
        )
        outer_app_sign_index = self._line_index("# Outer app signing seals the bundle.")

        self.assertLess(sparkle_sign_index, outer_app_sign_index)

    def _line_index(self, marker):
        for index, line in enumerate(self.release_script.splitlines()):
            if marker in line:
                return index
        self.fail(f"missing line containing {marker!r}")

    def _run_builder(self, *arguments):
        environment = os.environ.copy()
        environment.pop("LUNGFISH_SPARKLE_PUBLIC_ED_KEY", None)
        return subprocess.run(
            ["bash", str(self.release_script_path), *arguments],
            cwd=self.root,
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )


if __name__ == "__main__":
    unittest.main()
