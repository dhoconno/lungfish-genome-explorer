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
        source = self.root / "smoke-fixture.c"
        source.write_text(
            """
            #include <stdio.h>
            #include <stdlib.h>
            #include <string.h>
            #include <sys/stat.h>

            int main(int argc, char **argv) {
                if (argc == 2 && strcmp(argv[1], "--debug-relocation-smoke") == 0) {
                    const char *marker = getenv("DEBUG_SMOKE_APP_MARKER_PATH");
                    if (marker != NULL) {
                        FILE *handle = fopen(marker, "w");
                        if (handle == NULL) return 21;
                        fputs("executed\\n", handle);
                        fclose(handle);
                    }
                    puts("debug-app-executable-smoke-ok");
                    return 0;
                }
                if (getenv("RECREATE_BUILD_PATH") != NULL) {
                    const char *path = getenv("RECREATE_BUILD_PATH");
                    mkdir(path, 0700);
                    char marker[4096];
                    snprintf(marker, sizeof(marker), "%s/recreated", path);
                    FILE *handle = fopen(marker, "w");
                    if (handle != NULL) fclose(handle);
                }
                if (getenv("FAIL_DEBUG_CLI") != NULL) return 22;
                puts("debug-resource-smoke-ok");
                return 0;
            }
            """,
            encoding="utf-8",
        )
        executable = self.app / "Contents" / "MacOS" / "Lungfish"
        subprocess.run(
            ["xcrun", "clang", str(source), "-o", str(executable)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        shutil.copy2(executable, self.app / "Contents" / "MacOS" / "lungfish-cli")
        helpers = self.app / "Contents" / "Helpers"
        helpers.mkdir()
        self.nested_helper = helpers / "DeveloperLikeHelper"
        shutil.copy2(executable, self.nested_helper)
        self.info_plist = self.app / "Contents" / "Info.plist"
        self.write_plist({})
        self.sign_app()
        self.app_execution_marker = self.root / "app-executed"

    def write_plist(self, additions):
        values = {
            "CFBundleDisplayName": "Lungfish Genome Explorer Debug",
            "CFBundleName": "Lungfish Debug",
            "CFBundleIdentifier": "com.lungfish.browser.debug",
            "CFBundleExecutable": "Lungfish",
            "CFBundlePackageType": "APPL",
            "LungfishReleaseChannel": "debug",
            **additions,
        }
        with self.info_plist.open("wb") as handle:
            plistlib.dump(values, handle)

    def sign_app(self):
        for executable in (
            self.app / "Contents" / "MacOS" / "Lungfish",
            self.app / "Contents" / "MacOS" / "lungfish-cli",
            self.nested_helper,
        ):
            subprocess.run(
                [
                    "/usr/bin/codesign",
                    "--force",
                    "--sign",
                    "-",
                    "--timestamp=none",
                    str(executable),
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        subprocess.run(
            [
                "/usr/bin/codesign",
                "--force",
                "--deep",
                "--sign",
                "-",
                "--timestamp=none",
                str(self.app),
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def make_compiling_build(self):
        package = self.root / "package"
        package.mkdir()
        (package / "Package.swift").write_text(
            "// swift-tools-version: 6.2\n", encoding="utf-8"
        )
        build = package / ".build"
        build.mkdir()
        (build / "original").write_text("original\n", encoding="utf-8")
        return build

    def run_smoke(self, *, compiling_build=None, additions=None):
        command = ["bash", str(SMOKE), str(self.app)]
        if compiling_build is not None:
            command.extend(["--compiling-build-dir", str(compiling_build)])
        return subprocess.run(
            command,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                **os.environ,
                "LC_ALL": "C",
                "DEBUG_SMOKE_APP_MARKER_PATH": str(self.app_execution_marker),
                **(additions or {}),
            },
            check=False,
        )

    def test_relocates_debug_app_and_runs_non_ui_resource_probe(self):
        result = self.run_smoke()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Debug relocation/resource smoke passed", result.stdout)
        self.assertEqual(
            self.app_execution_marker.read_text(encoding="utf-8"), "executed\n"
        )

    def test_rejects_unsigned_app(self):
        subprocess.run(
            ["/usr/bin/codesign", "--remove-signature", str(self.app)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        result = self.run_smoke()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ad-hoc signature", result.stderr)

    def test_rejects_developer_identity_on_any_nested_signed_code(self):
        codesign_stub = self.root / "codesign-stub.sh"
        codesign_stub.write_text(
            """#!/bin/bash
target=""
for argument in "$@"; do target="$argument"; done
if [[ " $* " == *" --display "* ]] && [[ "$target" == */DeveloperLikeHelper ]]; then
    echo "Executable=$target" >&2
    echo "Signature=Developer ID" >&2
    echo "TeamIdentifier=FAKE123" >&2
    exit 0
fi
exec /usr/bin/codesign "$@"
""",
            encoding="utf-8",
        )
        codesign_stub.chmod(0o755)

        result = self.run_smoke(
            additions={
                "LUNGFISH_DEBUG_SMOKE_CODESIGN": str(codesign_stub),
                "LUNGFISH_DEBUG_SMOKE_TESTING": "1",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DeveloperLikeHelper", result.stderr)
        self.assertIn("exact ad-hoc signature", result.stderr)

    def test_rejects_any_sparkle_metadata(self):
        self.write_plist({"SUFeedURL": "https://example.invalid/appcast.xml"})
        self.sign_app()

        result = self.run_smoke()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Sparkle", result.stderr)

    def test_rejects_app_without_runtime_resource_bundles(self):
        shutil.rmtree(self.app / "Contents" / "Resources" / "Fixture.bundle")
        self.sign_app()

        result = self.run_smoke()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no runtime resource bundles", result.stderr)

    def test_failure_restores_hidden_build_tree(self):
        build = self.make_compiling_build()

        result = self.run_smoke(
            compiling_build=build,
            additions={"FAIL_DEBUG_CLI": "1"},
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((build / "original").is_file())
        self.assertFalse(Path(f"{build}.debug-resource-smoke-hidden").exists())

    def test_recreated_build_tree_is_never_overwritten_during_restore(self):
        build = self.make_compiling_build()

        result = self.run_smoke(
            compiling_build=build,
            additions={"RECREATE_BUILD_PATH": str(build)},
        )

        hidden = Path(f"{build}.debug-resource-smoke-hidden")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((build / "recreated").is_file())
        self.assertTrue((hidden / "original").is_file())
        self.assertIn(str(hidden), result.stderr)
        self.assertIn("recovery", result.stderr.lower())

    def test_repo_scoped_lock_rejects_concurrent_build_hide(self):
        build = self.make_compiling_build()
        lock = Path(f"{build}.debug-resource-smoke.lock")
        subprocess.run(
            ["/usr/bin/shlock", "-p", str(os.getpid()), "-f", str(lock)],
            check=True,
        )
        self.addCleanup(lock.unlink, missing_ok=True)

        result = self.run_smoke(compiling_build=build)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already in progress", result.stderr)
        self.assertTrue((build / "original").is_file())


if __name__ == "__main__":
    unittest.main()
