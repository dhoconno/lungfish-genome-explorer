"""Behavioral tests for release-machine preflight and Sparkle tool discovery."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import shutil
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
PYTHON = ROOT / ".ci-python" / "bin" / "python"
DOCTOR = ROOT / "scripts" / "release" / "release-doctor.py"
RESOLVER = ROOT / "scripts" / "release" / "resolve-sparkle-tools.sh"
NIGHTLY = ROOT / "scripts" / "release" / "run-nightly-prerelease.sh"


class ReleaseDoctorFixture:
    def __init__(self, case: unittest.TestCase):
        self.case = case
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.developer_dir = self.root / "Xcode.app" / "Contents" / "Developer"
        (self.developer_dir / "usr" / "bin").mkdir(parents=True)
        self._write_executable(
            self.developer_dir / "usr" / "bin" / "xcodebuild", "exit 0"
        )
        self.scratch = self.root / "scratch"
        self.sparkle = self.root / "sparkle" / "bin"
        self.sparkle.mkdir(parents=True)
        self.sparkle_log = self.root / "sparkle.log"
        self.sentinel = self.root / "release-output" / "keep.txt"
        self.sentinel.parent.mkdir()
        self.sentinel.write_text("untouched\n", encoding="utf-8")
        self._install_commands()
        self._install_sparkle_tools()
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "DEVELOPER_DIR": str(self.developer_dir),
            "LUNGFISH_RELEASE_SCRATCH_ROOT": str(self.scratch),
            "LUNGFISH_SPARKLE_TOOLS_DIR": str(self.sparkle),
            "STUB_XCODE_VERSION": "26.4.1",
            "STUB_SWIFT_VERSION": "6.2.3",
            "STUB_SDK_VERSION": "26.1",
            "STUB_ARCH": "arm64",
            "STUB_DEPLOYMENT_TARGET": "26.0",
            "STUB_DISK_AVAILABLE_KB": str(30 * 1024 * 1024),
            "STUB_SECURITY_IDENTITIES": (
                '  1) ABCDEF "Developer ID Application: Example Corp (TEAM123456)"\n'
                "     1 valid identities found\n"
            ),
            "STUB_NOTARY_OK": "1",
            "STUB_GH_AUTH_OK": "1",
            "STUB_GH_API_OK": "1",
            "STUB_GIT_STATUS": "",
            "STUB_SPARKLE_KEY_OK": "1",
            "STUB_SPARKLE_VERIFY_OK": "1",
            "STUB_SPARKLE_LOG": str(self.sparkle_log),
            "STUB_PYTHON": str(PYTHON),
        }

    def cleanup(self) -> None:
        self.temp.cleanup()

    def _write_executable(self, path: Path, body: str) -> None:
        path.write_text(f"#!/bin/bash\nset -eu\n{body}\n", encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _install_commands(self) -> None:
        self._write_executable(self.bin / "python3", 'exec "$STUB_PYTHON" "$@"')
        self._write_executable(
            self.bin / "xcodebuild",
            textwrap.dedent(
                """
                if [[ " $* " == *" -version "* ]]; then
                  printf 'Xcode %s\\nBuild version 17F80\\n' "$STUB_XCODE_VERSION"
                elif [[ " $* " == *" -showBuildSettings "* ]]; then
                  printf '    MACOSX_DEPLOYMENT_TARGET = %s\\n' "$STUB_DEPLOYMENT_TARGET"
                else
                  exit 65
                fi
                """
            ),
        )
        self._write_executable(
            self.bin / "xcrun",
            textwrap.dedent(
                """
                if [ "${1:-}" = "swift" ] && [ "${2:-}" = "--version" ]; then
                  printf 'Apple Swift version %s (swiftlang-test)\\n' "$STUB_SWIFT_VERSION"
                elif [ "${1:-}" = "--sdk" ] && [ "${2:-}" = "macosx" ] && [ "${3:-}" = "--show-sdk-version" ]; then
                  printf '%s\\n' "$STUB_SDK_VERSION"
                elif [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "history" ]; then
                  [ "$STUB_NOTARY_OK" = 1 ]
                else
                  exit 65
                fi
                """
            ),
        )
        self._write_executable(self.bin / "uname", "printf '%s\\n' \"$STUB_ARCH\"")
        self._write_executable(
            self.bin / "df",
            "printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n'\n"
            "printf 'stub 99999999 1 %s 1%% /\\n' \"$STUB_DISK_AVAILABLE_KB\"",
        )
        self._write_executable(
            self.bin / "git",
            textwrap.dedent(
                """
                case "${1:-} ${2:-}" in
                  "status --porcelain")
                    if [[ " $* " != *" --untracked-files=no "* ]]; then
                      printf '%s' "$STUB_GIT_STATUS"
                    fi
                    ;;
                  "rev-parse --verify") printf '0123456789abcdef0123456789abcdef01234567\\n' ;;
                  "remote get-url") printf 'https://github.com/example/lungfish.git\\n' ;;
                  *) exit 65 ;;
                esac
                """
            ),
        )
        self._write_executable(
            self.bin / "security",
            '[ "${1:-}" = find-identity ] || exit 65\nprintf \'%s\' "$STUB_SECURITY_IDENTITIES"',
        )
        self._write_executable(
            self.bin / "gh",
            textwrap.dedent(
                """
                if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
                  [ "$STUB_GH_AUTH_OK" = 1 ]
                elif [ "${1:-}" = api ]; then
                  [ "$STUB_GH_API_OK" = 1 ]
                else
                  exit 65
                fi
                """
            ),
        )

    def _install_sparkle_tools(self) -> None:
        self._write_executable(self.sparkle / "generate_appcast", "exit 0")
        self._write_executable(
            self.sparkle / "generate_keys",
            '[ "${1:-}" = -p ] || exit 65\n'
            '[ "$STUB_SPARKLE_KEY_OK" = 1 ] || exit 1\n'
            "printf 'public-key-placeholder\\n'",
        )
        self._write_executable(
            self.sparkle / "sign_update",
            textwrap.dedent(
                """
                file=''
                verify=0
                for arg in "$@"; do
                  [ "$arg" = "--verify" ] && verify=1
                  [ -f "$arg" ] && file="$arg"
                done
                [ -n "$file" ] || exit 65
                printf '%s\\n' "$file" >> "$STUB_SPARKLE_LOG"
                if [ "$verify" = 1 ]; then
                  [ "$STUB_SPARKLE_VERIFY_OK" = 1 ]
                else
                  printf 'probe-signature'
                fi
                """
            ),
        )

    def run_doctor(
        self, *, mode: str = "package", env: dict[str, str] | None = None, extra=()
    ):
        command = [str(PYTHON), str(DOCTOR), "--mode", mode, "--channel", "preview"]
        if mode == "credentials":
            command.extend(
                [
                    "--signing-identity",
                    "Developer ID Application: Example Corp (TEAM123456)",
                    "--team-id",
                    "TEAM123456",
                    "--notary-profile",
                    "test-notary",
                ]
            )
        command.extend(extra)
        result = subprocess.run(
            command,
            cwd=ROOT,
            env=env or self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )
        if result.returncode != 0:
            self.case.assertEqual(
                self.sentinel.read_text(encoding="utf-8"), "untouched\n"
            )
        return result


class ReleaseDoctorTests(unittest.TestCase):
    def setUp(self):
        self.fx = ReleaseDoctorFixture(self)

    def tearDown(self):
        self.fx.cleanup()

    def assert_failure(self, expected: str, *, mode="package", env=None, extra=()):
        result = self.fx.run_doctor(mode=mode, env=env, extra=extra)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(expected, result.stdout + result.stderr)

    def test_rejects_missing_or_wrong_xcode_selection(self):
        env = {**self.fx.env, "DEVELOPER_DIR": str(self.fx.root / "missing-xcode")}
        self.assert_failure("Xcode selection", env=env)

    def test_rejects_developer_directory_with_non_executable_xcodebuild(self):
        selected_xcodebuild = self.fx.developer_dir / "usr" / "bin" / "xcodebuild"
        selected_xcodebuild.chmod(0o644)
        self.assert_failure("Xcode selection")

    def test_rejects_xcode_outside_contract_range(self):
        env = {**self.fx.env, "STUB_XCODE_VERSION": "27.0"}
        self.assert_failure("Xcode version", env=env)

    def test_rejects_swift_outside_contract_range(self):
        env = {**self.fx.env, "STUB_SWIFT_VERSION": "7.0"}
        self.assert_failure("Swift version", env=env)

    def test_rejects_sdk_major_mismatch(self):
        env = {**self.fx.env, "STUB_SDK_VERSION": "25.4"}
        self.assert_failure("macOS SDK", env=env)

    def test_rejects_non_arm64_host(self):
        env = {**self.fx.env, "STUB_ARCH": "x86_64"}
        self.assert_failure("host architecture", env=env)

    def test_rejects_project_deployment_target_mismatch(self):
        env = {**self.fx.env, "STUB_DEPLOYMENT_TARGET": "15.0"}
        self.assert_failure("deployment target", env=env)

    def test_rejects_insufficient_disk_space(self):
        env = {**self.fx.env, "STUB_DISK_AVAILABLE_KB": str(2 * 1024 * 1024)}
        self.assert_failure("free disk", env=env)

    def test_rejects_unwritable_deterministic_scratch_root(self):
        blocked = self.fx.root / "not-a-directory"
        blocked.write_text("blocked", encoding="utf-8")
        env = {**self.fx.env, "LUNGFISH_RELEASE_SCRATCH_ROOT": str(blocked)}
        self.assert_failure("scratch root", env=env)

    def test_rejects_untracked_source_files(self):
        env = {**self.fx.env, "STUB_GIT_STATUS": "?? Sources/Unexpected.swift\n"}
        self.assert_failure("clean source tree", env=env)

    def test_rejects_missing_signing_identity(self):
        env = {**self.fx.env, "STUB_SECURITY_IDENTITIES": "0 valid identities found\n"}
        self.assert_failure("signing identity", mode="credentials", env=env)

    def test_rejects_signing_identity_team_mismatch(self):
        env = {
            **self.fx.env,
            "STUB_SECURITY_IDENTITIES": (
                '1) ABC "Developer ID Application: Example Corp (OTHERTEAM1)"\n'
            ),
        }
        self.assert_failure(
            "Team ID",
            mode="credentials",
            env=env,
            extra=(
                "--signing-identity",
                "Developer ID Application: Example Corp (OTHERTEAM1)",
            ),
        )

    def test_rejects_locked_or_missing_notary_profile(self):
        env = {**self.fx.env, "STUB_NOTARY_OK": "0"}
        self.assert_failure("notary profile", mode="credentials", env=env)

    def test_rejects_github_auth_and_repository_api_failures(self):
        for variable, expected in (
            ("STUB_GH_AUTH_OK", "GitHub authentication"),
            ("STUB_GH_API_OK", "GitHub repository API"),
        ):
            with self.subTest(variable=variable):
                env = {**self.fx.env, variable: "0"}
                self.assert_failure(expected, mode="credentials", env=env)

    def test_rejects_missing_sparkle_tools(self):
        missing = self.fx.root / "missing-sparkle-tools"
        env = {**self.fx.env, "LUNGFISH_SPARKLE_TOOLS_DIR": str(missing)}
        self.assert_failure("Sparkle tools", env=env)

    def test_rejects_inaccessible_sparkle_keychain_key(self):
        env = {**self.fx.env, "STUB_SPARKLE_KEY_OK": "0"}
        self.assert_failure("Sparkle Keychain key", mode="credentials", env=env)

    def test_keychain_probe_signs_verifies_and_removes_disposable_file(self):
        result = self.fx.run_doctor(mode="credentials")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS Sparkle sign/verify probe", result.stdout)
        probe_paths = self.fx.sparkle_log.read_text(encoding="utf-8").splitlines()
        self.assertGreaterEqual(len(probe_paths), 2)
        self.assertTrue(all(not Path(path).exists() for path in probe_paths))

    def test_json_report_is_redacted_and_private(self):
        report = self.fx.root / "doctor.json"
        secret_file = self.fx.root / "do-not-print-this-private-key-name"
        secret_file.write_text("private-key-material", encoding="utf-8")
        secret_file.chmod(0o600)
        result = self.fx.run_doctor(
            mode="credentials",
            extra=(
                "--sparkle-ed-key-file",
                str(secret_file),
                "--json-report",
                str(report),
            ),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        payload = report.read_text(encoding="utf-8")
        json.loads(payload)
        self.assertNotIn(str(secret_file), payload + result.stdout + result.stderr)
        self.assertNotIn(
            "private-key-material", payload + result.stdout + result.stderr
        )
        self.assertEqual(stat.S_IMODE(report.stat().st_mode), 0o600)


class SparkleResolverTests(unittest.TestCase):
    def test_resolver_emits_absolute_executable_tool_paths_without_touching_lockfile(
        self,
    ):
        with tempfile.TemporaryDirectory() as temp:
            tools = Path(temp) / "Sparkle Tools"
            tools.mkdir()
            for name in ("generate_appcast", "sign_update", "generate_keys"):
                path = tools / name
                path.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
                path.chmod(0o755)
            before = (ROOT / "Package.resolved").read_bytes()
            result = subprocess.run(
                ["/bin/bash", str(RESOLVER)],
                cwd=ROOT,
                env={**os.environ, "LUNGFISH_SPARKLE_TOOLS_DIR": str(tools)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            values = {}
            for assignment in shlex.split(result.stdout):
                key, value = assignment.split("=", 1)
                values[key] = value
            self.assertEqual(
                set(values),
                {
                    "SPARKLE_GENERATE_APPCAST",
                    "SPARKLE_SIGN_UPDATE",
                    "SPARKLE_GENERATE_KEYS",
                },
            )
            self.assertTrue(all(Path(value).is_absolute() for value in values.values()))
            self.assertEqual((ROOT / "Package.resolved").read_bytes(), before)

    def test_resolver_uses_a_minimal_package_derived_from_the_tracked_sparkle_pin(self):
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp) / "repo"
            release_scripts = repo / "scripts" / "release"
            release_scripts.mkdir(parents=True)
            resolver = release_scripts / "resolve-sparkle-tools.sh"
            shutil.copy2(RESOLVER, resolver)
            (repo / "Package.swift").write_text(
                "// swift-tools-version: 6.2\nORIGINAL_MANIFEST_SENTINEL\n",
                encoding="utf-8",
            )
            shutil.copy2(ROOT / "Package.resolved", repo / "Package.resolved")
            before = (repo / "Package.resolved").read_bytes()
            bin_dir = Path(temp) / "bin"
            bin_dir.mkdir()
            manifest_log = Path(temp) / "resolved-manifest.txt"
            resolved_log = Path(temp) / "resolved-lock.json"
            xcrun = bin_dir / "xcrun"
            xcrun.write_text(
                "#!/bin/bash\nset -eu\n"
                "package_path=''\nscratch_path=''\n"
                "while [ $# -gt 0 ]; do\n"
                '  case "$1" in\n'
                "    --package-path) package_path=$2; shift 2 ;;\n"
                "    --scratch-path) scratch_path=$2; shift 2 ;;\n"
                "    *) shift ;;\n"
                "  esac\n"
                "done\n"
                'cp "$package_path/Package.swift" "$STUB_MANIFEST_LOG"\n'
                'cp "$package_path/Package.resolved" "$STUB_RESOLVED_LOG"\n'
                'tools="$scratch_path/artifacts/sparkle/Sparkle/bin"\n'
                'mkdir -p "$tools"\n'
                "for name in generate_appcast sign_update generate_keys; do\n"
                "  printf '#!/bin/bash\\nexit 0\\n' > \"$tools/$name\"\n"
                '  chmod +x "$tools/$name"\n'
                "done\n",
                encoding="utf-8",
            )
            xcrun.chmod(0o755)
            result = subprocess.run(
                ["/bin/bash", str(resolver)],
                cwd=repo,
                env={
                    **os.environ,
                    "PATH": f"{bin_dir}:/usr/bin:/bin",
                    "LUNGFISH_RELEASE_SCRATCH_ROOT": str(Path(temp) / "scratch"),
                    "STUB_MANIFEST_LOG": str(manifest_log),
                    "STUB_RESOLVED_LOG": str(resolved_log),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            manifest = manifest_log.read_text(encoding="utf-8")
            self.assertNotIn("ORIGINAL_MANIFEST_SENTINEL", manifest)
            self.assertIn("https://github.com/sparkle-project/Sparkle", manifest)
            self.assertIn('exact: "2.9.6"', manifest)
            resolved_identities = [
                pin["identity"]
                for pin in json.loads(resolved_log.read_text(encoding="utf-8"))["pins"]
            ]
            self.assertEqual(resolved_identities, ["sparkle"])
            self.assertEqual((repo / "Package.resolved").read_bytes(), before)

            changed_lock = json.loads(
                (repo / "Package.resolved").read_text(encoding="utf-8")
            )
            sparkle_pin = next(
                pin for pin in changed_lock["pins"] if pin["identity"] == "sparkle"
            )
            sparkle_pin["state"]["version"] = "9.9.9"
            (repo / "Package.resolved").write_text(
                json.dumps(changed_lock), encoding="utf-8"
            )
            changed_before = (repo / "Package.resolved").read_bytes()
            rerun = subprocess.run(
                ["/bin/bash", str(resolver)],
                cwd=repo,
                env={
                    **os.environ,
                    "PATH": f"{bin_dir}:/usr/bin:/bin",
                    "LUNGFISH_RELEASE_SCRATCH_ROOT": str(Path(temp) / "scratch"),
                    "STUB_MANIFEST_LOG": str(manifest_log),
                    "STUB_RESOLVED_LOG": str(resolved_log),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(rerun.returncode, 0, rerun.stdout + rerun.stderr)
            self.assertIn('exact: "9.9.9"', manifest_log.read_text(encoding="utf-8"))
            self.assertEqual((repo / "Package.resolved").read_bytes(), changed_before)


class NightlyReleaseProfileTests(unittest.TestCase):
    def test_wrapper_reads_machine_values_from_ignored_profile_and_explicit_flags_override(
        self,
    ):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp) / "home"
            profile = home / ".config" / "lungfish" / "release.env"
            profile.parent.mkdir(parents=True)
            profile.write_text(
                "LUNGFISH_SIGNING_IDENTITY='Developer ID Application: Profile Corp (PROFILE123)'\n"
                "LUNGFISH_TEAM_ID='PROFILE123'\n"
                "LUNGFISH_NOTARY_PROFILE='profile-notary'\n",
                encoding="utf-8",
            )
            bin_dir = Path(temp) / "bin"
            bin_dir.mkdir()
            captured = Path(temp) / "args.json"
            python_stub = bin_dir / "python3"
            python_stub.write_text(
                "#!/usr/bin/python3\nimport json, os, sys\n"
                "open(os.environ['CAPTURE_ARGS'], 'w').write(json.dumps(sys.argv[1:]))\n",
                encoding="utf-8",
            )
            python_stub.chmod(0o755)
            tools = Path(temp) / "sparkle"
            tools.mkdir()
            for name in ("generate_appcast", "sign_update", "generate_keys"):
                tool = tools / name
                tool.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
                tool.chmod(0o755)
            result = subprocess.run(
                [
                    "/bin/bash",
                    str(NIGHTLY),
                    "--team-id",
                    "EXPLICIT99",
                    "--signing-identity",
                    "Developer ID Application: Explicit Corp (EXPLICIT99)",
                ],
                cwd=ROOT,
                env={
                    **os.environ,
                    "HOME": str(home),
                    "PATH": f"{bin_dir}:/usr/bin:/bin",
                    "CAPTURE_ARGS": str(captured),
                    "LUNGFISH_SPARKLE_TOOLS_DIR": str(tools),
                    "LUNGFISH_NOTARY_PROFILE": "environment-notary",
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            args = json.loads(captured.read_text(encoding="utf-8"))
            self.assertIn("environment-notary", args)
            self.assertNotIn("profile-notary", args)
            self.assertIn("EXPLICIT99", args)
            self.assertIn("Developer ID Application: Explicit Corp (EXPLICIT99)", args)
            self.assertNotIn("PROFILE123", args)

    def test_explicit_sparkle_tool_does_not_require_automatic_resolution(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp) / "home"
            home.mkdir()
            bin_dir = Path(temp) / "bin"
            bin_dir.mkdir()
            captured = Path(temp) / "args.json"
            python_stub = bin_dir / "python3"
            python_stub.write_text(
                "#!/usr/bin/python3\nimport json, os, sys\n"
                "open(os.environ['CAPTURE_ARGS'], 'w').write(json.dumps(sys.argv[1:]))\n",
                encoding="utf-8",
            )
            python_stub.chmod(0o755)
            explicit_tool = Path(temp) / "explicit-generate-appcast"
            explicit_tool.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
            explicit_tool.chmod(0o755)
            result = subprocess.run(
                [
                    "/bin/bash",
                    str(NIGHTLY),
                    "--sparkle-generate-appcast",
                    str(explicit_tool),
                ],
                cwd=ROOT,
                env={
                    **os.environ,
                    "HOME": str(home),
                    "PATH": f"{bin_dir}:/usr/bin:/bin",
                    "CAPTURE_ARGS": str(captured),
                    "LUNGFISH_SPARKLE_TOOLS_DIR": str(Path(temp) / "missing"),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("Sparkle tools:", result.stderr)
            args = json.loads(captured.read_text(encoding="utf-8"))
            self.assertIn(str(explicit_tool), args)


if __name__ == "__main__":
    unittest.main()
