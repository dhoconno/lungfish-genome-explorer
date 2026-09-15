#!/usr/bin/env python3
"""Lock shared SwiftPM options and resolved product directories in helpers."""

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class SwiftPMHelperEngineTests(unittest.TestCase):
    def assert_shared_swiftbuild_commands(self, relative_path, expected_commands):
        script = (ROOT / relative_path).read_text()
        actual_commands = [
            line.strip()
            for line in script.splitlines()
            if "swift build" in line and not line.strip().startswith("#")
        ]
        self.assertEqual(actual_commands, expected_commands)
        self.assertIn("scripts/release/swiftpm_build.py", script)
        self.assertIn('SWIFTPM_OPTIONS="$(python3 ', script)
        self.assertIn(
            'while IFS= read -r option; do SWIFT_BUILD_ARGS+=("$option"); done <<< "$SWIFTPM_OPTIONS"',
            script,
        )
        self.assertTrue(all('"${SWIFT_BUILD_ARGS[@]}"' in command for command in actual_commands))
        self.assertNotIn(".build/debug", script)
        self.assertNotIn("--build-system native", script)

    def test_dependency_verifier_build_and_lookup_use_swiftbuild(self):
        self.assert_shared_swiftbuild_commands(
            "scripts/deps/verify.sh",
            [
                'swift build "${SWIFT_BUILD_ARGS[@]}" --product lungfish-cli >/dev/null',
                'cli="$(swift build "${SWIFT_BUILD_ARGS[@]}" --product lungfish-cli --show-bin-path)/lungfish-cli"',
            ],
        )

    def test_xcui_build_and_lookup_use_identical_swiftbuild_options(self):
        self.assert_shared_swiftbuild_commands(
            "scripts/testing/run-macos-xcui.sh",
            [
                'swift build "${SWIFT_BUILD_ARGS[@]}" --package-path "$ROOT_DIR" --product lungfish-cli',
                'LUNGFISH_CLI_BIN_PATH="$(swift build "${SWIFT_BUILD_ARGS[@]}" --package-path "$ROOT_DIR" --product lungfish-cli --show-bin-path)/lungfish-cli"',
            ],
        )
        script = (ROOT / "scripts/testing/run-macos-xcui.sh").read_text()
        self.assertIn(
            'echo "error: resolved lungfish-cli path is not executable:', script
        )
        self.assertNotIn('LUNGFISH_CLI_BIN_PATH=""', script)

    def test_vcf_debug_helper_build_and_lookup_use_swiftbuild(self):
        self.assert_shared_swiftbuild_commands(
            "scripts/debug-vcf-import-helper.sh",
            [
                'BINARY_PATH="$(swift build "${SWIFT_BUILD_ARGS[@]}" --package-path "$REPO_ROOT" --product Lungfish --show-bin-path)/Lungfish"',
                'swift build "${SWIFT_BUILD_ARGS[@]}" --package-path "$REPO_ROOT" --product Lungfish >/dev/null',
            ],
        )


if __name__ == "__main__":
    unittest.main()
