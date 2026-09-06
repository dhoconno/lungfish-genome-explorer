import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONTRACT_PATH = ROOT / "config" / "release-contract.json"
LOADER_PATH = ROOT / "scripts" / "release" / "release_contract.py"
BUILDER_PATH = ROOT / "scripts" / "release" / "build-notarized-dmg.sh"


EXPECTED_CHANNELS = {
    "preview": {
        "appBundleFilename": "Lungfish Preview.app",
        "displayName": "Lungfish Genome Explorer Preview",
        "bundleName": "Lungfish Preview",
        "bundleIdentifier": "com.lungfish.browser.preview",
        "releaseChannel": "preview",
        "sparkleRelease": "sparkle-beta",
        "appcastFilename": "appcast-beta.xml",
        "githubPrerelease": True,
        "dmgVolumeName": "Lungfish Preview",
        "legacyBridgeRelease": "sparkle-alpha",
        "legacyBridgeAppcastFilename": "appcast-alpha.xml",
    },
    "stable": {
        "appBundleFilename": "Lungfish.app",
        "displayName": "Lungfish Genome Explorer",
        "bundleName": "Lungfish",
        "bundleIdentifier": "com.lungfish.browser",
        "releaseChannel": "stable",
        "sparkleRelease": "sparkle-stable",
        "appcastFilename": "appcast-stable.xml",
        "githubPrerelease": False,
        "dmgVolumeName": "Lungfish",
        "legacyBridgeRelease": "",
        "legacyBridgeAppcastFilename": "",
    },
}

EXPECTED_BUILD_PROFILES = {
    "debug": {
        "appBundleFilename": "Lungfish Debug.app",
        "displayName": "Lungfish Genome Explorer Debug",
        "bundleName": "Lungfish Debug",
        "bundleIdentifier": "com.lungfish.browser.debug",
        "releaseChannel": "debug",
        "isRelease": False,
        "publishable": False,
        "updaterEnabled": False,
    }
}

EXPECTED_TOOLCHAIN = {
    "xcodeMinimum": "26.4.1",
    "xcodeMaximumExclusive": "27.0",
    "swiftMinimum": "6.2",
    "swiftMaximumExclusive": "7.0",
    "sdkMajor": 26,
    "deploymentTarget": "26.0",
    "architecture": "arm64",
    "minimumFreeDiskGiB": 20,
}

EXPECTED_GATES = {
    "appSmokeAccount": "lungfish-release-qa",
    "appSmokeTests": ['LungfishXCUITests/MainWindowNavigationXCUITests/testReleaseCandidateLaunchAndChannelIdentity', 'LungfishXCUITests/MainWindowNavigationXCUITests/testReleaseCandidateImportFailureStatus', 'LungfishXCUITests/ProjectLifecycleXCUITests/testReleaseCandidateNativeOpenSaveCloseReopen', 'LungfishXCUITests/ProjectLifecycleXCUITests/testReleaseCandidateTwoWindowOwnership', 'LungfishXCUITests/BundleBrowserXCUITests/testReleaseCandidateNativeBundleBrowser'],
    "dependencyPolicy": "manifest",
    "appSmokeRequired": False,
    "focusedReleaseTests": [
        "scripts.tests.test_test_catalog",
        "scripts.tests.test_release_contract",
        "scripts.tests.test_full_suite_gate_tiers",
        "scripts.tests.test_gate_profile_evidence",
        "scripts.tests.test_release_identity",
        "scripts.tests.test_release_notes_preflight",
    ],
    "channels": {
        "preview": [{"tier": "release", "requireTools": False}],
        "stable": [{"tier": "release", "requireTools": False}],
    },
}


def load_release_contract_module():
    spec = importlib.util.spec_from_file_location("release_contract", LOADER_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load release contract module: {LOADER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ReleaseContractTests(unittest.TestCase):
    def setUp(self):
        self.module = load_release_contract_module()
        self.raw_contract = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))

    def contract_with_expected_gates(self):
        data = copy.deepcopy(self.raw_contract)
        data["gates"] = copy.deepcopy(EXPECTED_GATES)
        return data

    def contract_with_expected_profiles(self):
        data = copy.deepcopy(self.raw_contract)
        data["buildProfiles"] = copy.deepcopy(EXPECTED_BUILD_PROFILES)
        return data

    def write_contract(self, data):
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)
        path = Path(temp_dir.name) / "release-contract.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def test_rejects_unsafe_output_filenames_in_every_channel_and_debug(self):
        fields = [('channels', 'stable', 'appBundleFilename', '.app'),
                  ('channels', 'preview', 'appcastFilename', '.xml'),
                  ('channels', 'preview', 'legacyBridgeAppcastFilename', '.xml'),
                  ('buildProfiles', 'debug', 'appBundleFilename', '.app')]
        for group, channel, field, suffix in fields:
            invalid = ['../outside' + suffix, '/private/outside' + suffix,
                       'subdir/file' + suffix, 'subdir\\file' + suffix, 'disk:file' + suffix,
                       'unsafe\x00' + suffix, 'unsafe\u0085' + suffix, 'name' + suffix + ' ',
                       ' name' + suffix, '.', '..', suffix, 'wrong-extension.txt']
            for filename in invalid:
                with self.subTest(field=field, filename=filename):
                    value = copy.deepcopy(self.raw_contract)
                    value[group][channel][field] = filename
                    with self.assertRaises(ValueError):
                        self.module.load_contract(self.write_contract(value))

    def test_safe_leaf_filenames_and_empty_legacy_bridge_are_preserved(self):
        value = copy.deepcopy(self.raw_contract)
        value['channels']['stable']['appBundleFilename'] = 'Safe Product.app'
        value['channels']['stable']['appcastFilename'] = 'safe-product.xml'
        loaded = self.module.load_contract(self.write_contract(value))
        self.assertEqual(loaded.channel('stable').appBundleFilename, 'Safe Product.app')
        self.assertEqual(loaded.channel('stable').legacyBridgeAppcastFilename, '')

    def test_real_contract_has_literal_channel_and_toolchain_policy(self):
        contract = self.module.load_contract(CONTRACT_PATH)

        self.assertEqual(contract.to_dict()["channels"], EXPECTED_CHANNELS)
        rendered = contract.to_dict()
        self.assertIn("buildProfiles", rendered)
        self.assertEqual(rendered["buildProfiles"], EXPECTED_BUILD_PROFILES)
        self.assertEqual(contract.to_dict()["toolchain"], EXPECTED_TOOLCHAIN)
        self.assertEqual(contract.to_dict()["gates"], EXPECTED_GATES)
        for name, expected in EXPECTED_CHANNELS.items():
            with self.subTest(channel=name):
                self.assertEqual(contract.channel(name).to_dict(), expected)
                self.assertIs(
                    contract.channel(name).githubPrerelease,
                    expected["githubPrerelease"],
                )
        self.assertEqual(
            contract.profile("debug").to_dict(), EXPECTED_BUILD_PROFILES["debug"]
        )

    def test_debug_profile_is_not_a_release_channel(self):
        contract = self.module.load_contract(CONTRACT_PATH)

        with self.assertRaisesRegex(ValueError, "unknown release channel"):
            contract.channel("debug")
        self.assertTrue(
            hasattr(contract, "profile"), "contract has no build profile API"
        )
        with self.assertRaisesRegex(ValueError, "unknown build profile"):
            contract.profile("preview")

    def test_debug_profile_rejects_release_updater_and_publication_fields(self):
        forbidden_fields = {
            "sparkleRelease": "sparkle-debug",
            "appcastFilename": "appcast-debug.xml",
            "sparklePublicKey": "public-key",
            "githubPrerelease": True,
            "dmgVolumeName": "Lungfish Debug",
            "legacyBridgeRelease": "sparkle-alpha",
            "legacyBridgeAppcastFilename": "appcast-alpha.xml",
            "githubRepository": "example/lungfish",
            "publicationTag": "debug",
        }

        for field, value in forbidden_fields.items():
            with self.subTest(field=field):
                mutated = self.contract_with_expected_profiles()
                mutated["buildProfiles"]["debug"][field] = value
                with self.assertRaisesRegex(ValueError, "build profile debug fields"):
                    self.module.load_contract(self.write_contract(mutated))

    def test_unknown_channel_is_rejected(self):
        contract = self.module.load_contract(CONTRACT_PATH)

        with self.assertRaisesRegex(ValueError, "unknown release channel"):
            contract.channel("nightly")

    def test_missing_and_extra_fields_are_rejected_at_every_schema_level(self):
        mutations = []

        missing_top = copy.deepcopy(self.raw_contract)
        del missing_top["toolchain"]
        mutations.append(("missing top-level", missing_top))

        extra_top = copy.deepcopy(self.raw_contract)
        extra_top["unexpected"] = True
        mutations.append(("extra top-level", extra_top))

        missing_profile = self.contract_with_expected_profiles()
        del missing_profile["buildProfiles"]["debug"]
        mutations.append(("missing debug profile", missing_profile))

        unknown_profile = self.contract_with_expected_profiles()
        unknown_profile["buildProfiles"]["nightly"] = copy.deepcopy(
            unknown_profile["buildProfiles"]["debug"]
        )
        mutations.append(("unknown build profile", unknown_profile))

        missing_channel = copy.deepcopy(self.raw_contract)
        del missing_channel["channels"]["preview"]["bundleName"]
        mutations.append(("missing channel field", missing_channel))

        extra_channel = copy.deepcopy(self.raw_contract)
        extra_channel["channels"]["stable"]["unexpected"] = "value"
        mutations.append(("extra channel field", extra_channel))

        unknown_channel = copy.deepcopy(self.raw_contract)
        unknown_channel["channels"]["nightly"] = copy.deepcopy(
            unknown_channel["channels"]["preview"]
        )
        mutations.append(("unknown channel", unknown_channel))

        missing_toolchain = copy.deepcopy(self.raw_contract)
        del missing_toolchain["toolchain"]["architecture"]
        mutations.append(("missing toolchain field", missing_toolchain))

        extra_toolchain = copy.deepcopy(self.raw_contract)
        extra_toolchain["toolchain"]["xcodeBuild"] = "17F80"
        mutations.append(("extra toolchain field", extra_toolchain))

        missing_gates = self.contract_with_expected_gates()
        del missing_gates["gates"]
        mutations.append(("missing gates", missing_gates))

        extra_gates = self.contract_with_expected_gates()
        extra_gates["gates"]["unexpected"] = True
        mutations.append(("extra gates field", extra_gates))

        for label, mutation in mutations:
            with self.subTest(mutation=label):
                with self.assertRaisesRegex(ValueError, "fields|channels|profiles"):
                    self.module.load_contract(self.write_contract(mutation))

    def test_contract_rejects_missing_duplicate_or_unsafe_release_gates(self):
        mutations = []

        missing_channel = self.contract_with_expected_gates()
        del missing_channel["gates"]["channels"]["preview"]
        mutations.append(("missing gate channel", missing_channel))

        duplicate_tier = self.contract_with_expected_gates()
        duplicate_tier["gates"]["channels"]["preview"].append(
            {"tier": "release", "requireTools": False}
        )
        mutations.append(("duplicate tier", duplicate_tier))

        unsafe_module = self.contract_with_expected_gates()
        unsafe_module["gates"]["focusedReleaseTests"] = ["-m", "os"]
        mutations.append(("unsafe focused module", unsafe_module))

        wrong_require_tools = self.contract_with_expected_gates()
        wrong_require_tools["gates"]["channels"]["stable"] = [{"tier": "conformance", "requireTools": False}]
        mutations.append(("conformance without required tools", wrong_require_tools))

        for label, mutation in mutations:
            with self.subTest(mutation=label):
                with self.assertRaisesRegex(
                    ValueError, "gate|tier|focused|requireTools"
                ):
                    self.module.load_contract(self.write_contract(mutation))

    def test_contract_rejects_non_boolean_github_prerelease(self):
        mutated = copy.deepcopy(self.raw_contract)
        mutated["channels"]["preview"]["githubPrerelease"] = "true"

        with self.assertRaisesRegex(ValueError, "githubPrerelease"):
            self.module.load_contract(self.write_contract(mutated))

    def test_contract_rejects_duplicate_app_filenames_and_feeds(self):
        mutations = []

        duplicate_app = copy.deepcopy(self.raw_contract)
        duplicate_app["channels"]["stable"]["appBundleFilename"] = duplicate_app[
            "channels"
        ]["preview"]["appBundleFilename"]
        mutations.append(("app bundle filename", duplicate_app))

        duplicate_release = copy.deepcopy(self.raw_contract)
        duplicate_release["channels"]["stable"]["sparkleRelease"] = duplicate_release[
            "channels"
        ]["preview"]["sparkleRelease"]
        mutations.append(("Sparkle release", duplicate_release))

        duplicate_appcast = copy.deepcopy(self.raw_contract)
        duplicate_appcast["channels"]["stable"]["appcastFilename"] = duplicate_appcast[
            "channels"
        ]["preview"]["appcastFilename"]
        mutations.append(("appcast filename", duplicate_appcast))

        for label, mutation in mutations:
            with self.subTest(duplicate=label):
                with self.assertRaisesRegex(ValueError, "duplicate"):
                    self.module.load_contract(self.write_contract(mutation))

    def test_contract_rejects_duplicate_appcast_filenames_across_primary_and_legacy_feeds(
        self,
    ):
        mutations = []

        primary_matches_legacy = copy.deepcopy(self.raw_contract)
        primary_matches_legacy["channels"]["stable"][
            "appcastFilename"
        ] = primary_matches_legacy["channels"]["preview"]["legacyBridgeAppcastFilename"]
        mutations.append(("primary matches legacy", primary_matches_legacy))

        legacy_matches_primary = copy.deepcopy(self.raw_contract)
        legacy_matches_primary["channels"]["stable"][
            "legacyBridgeRelease"
        ] = "sparkle-stable-legacy"
        legacy_matches_primary["channels"]["stable"][
            "legacyBridgeAppcastFilename"
        ] = legacy_matches_primary["channels"]["preview"]["appcastFilename"]
        mutations.append(("legacy matches primary", legacy_matches_primary))

        duplicate_legacy = copy.deepcopy(self.raw_contract)
        duplicate_legacy["channels"]["stable"][
            "legacyBridgeRelease"
        ] = "sparkle-stable-legacy"
        duplicate_legacy["channels"]["stable"][
            "legacyBridgeAppcastFilename"
        ] = duplicate_legacy["channels"]["preview"]["legacyBridgeAppcastFilename"]
        mutations.append(("legacy matches legacy", duplicate_legacy))

        for label, mutation in mutations:
            with self.subTest(duplicate=label):
                with self.assertRaisesRegex(ValueError, "duplicate.*appcast"):
                    self.module.load_contract(self.write_contract(mutation))

    def test_builder_describe_channel_matches_contract_without_credentials(self):
        for name, expected in EXPECTED_CHANNELS.items():
            with self.subTest(channel=name):
                result = subprocess.run(
                    ["bash", str(BUILDER_PATH), "--describe-channel", name],
                    cwd=ROOT,
                    text=True,
                    capture_output=True,
                    check=False,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), expected)

    def test_debug_profile_cli_matches_contract(self):
        result = subprocess.run(
            [
                sys.executable,
                str(LOADER_PATH),
                "describe-profile",
                "--profile",
                "debug",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), EXPECTED_BUILD_PROFILES["debug"])

    def test_public_build_app_release_mode_is_retired_before_build(self):
        result = subprocess.run(
            ["bash", str(ROOT / "scripts" / "build-app.sh"), "--release"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            timeout=10,
        )

        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("retired", result.stdout + result.stderr)
        self.assertIn(
            "build-notarized-dmg.sh --package-only", result.stdout + result.stderr
        )

    def test_contract_cli_get_preserves_json_boolean_values(self):
        result = subprocess.run(
            [
                sys.executable,
                str(LOADER_PATH),
                "get",
                "--channel",
                "stable",
                "--field",
                "githubPrerelease",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "false\n")


if __name__ == "__main__":
    unittest.main()
