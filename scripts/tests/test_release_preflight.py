"""Behavioral tests for release-machine preflight and Sparkle tool discovery."""

from __future__ import annotations

import json
import hashlib
import importlib.util
import os
from pathlib import Path
import shlex
import stat
import subprocess
import shutil
import sys
import tempfile
import textwrap
import unittest
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[2]
PYTHON = ROOT / ".ci-python" / "bin" / "python"
DOCTOR = ROOT / "scripts" / "release" / "release-doctor.py"
RESOLVER = ROOT / "scripts" / "release" / "resolve-sparkle-tools.sh"
NIGHTLY = ROOT / "scripts" / "release" / "run-nightly-prerelease.sh"


def write_tool_trio(directory: Path, body: str = "exit 0") -> None:
    directory.mkdir(parents=True, exist_ok=True)
    for name in ("generate_appcast", "sign_update", "generate_keys"):
        path = directory / name
        path.write_text(f"#!/bin/bash\n{body}\n", encoding="utf-8")
        path.chmod(0o755)


def resolved_lock_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ReleaseDoctorFixture:
    def __init__(self, case: unittest.TestCase):
        self.case = case
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
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
        self.sentinel_root = self.root / "release-output"
        self.sentinel = self.sentinel_root / "keep.txt"
        self.sentinel_root.mkdir()
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
            "STUB_GH_CAN_PUSH": "true",
            "STUB_GIT_STATUS": "",
            "STUB_SPARKLE_KEY_OK": "1",
            "STUB_SPARKLE_HELP_OK": "1",
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
                  if [ -n "${STUB_PACKAGE_LOCK_SENTINEL:-}" ] \
                    && [[ " $* " != *" -disableAutomaticPackageResolution "* ]]; then
                    printf 'mutated\\n' >"$STUB_PACKAGE_LOCK_SENTINEL"
                  fi
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
                  [ "$STUB_GH_API_OK" = 1 ] || exit 1
                  if [[ " $* " == *" .permissions.push "* ]]; then
                    printf '%s\\n' "$STUB_GH_CAN_PUSH"
                  fi
                else
                  exit 65
                fi
                """
            ),
        )

    def _install_sparkle_tools(self) -> None:
        self._write_executable(
            self.sparkle / "generate_appcast",
            '[ "${1:-}" != --help ] || [ "$STUB_SPARKLE_HELP_OK" = 1 ]',
        )
        self._write_executable(
            self.sparkle / "generate_keys",
            'if [ "${1:-}" = --help ]; then [ "$STUB_SPARKLE_HELP_OK" = 1 ]; exit; fi\n'
            '[ "${1:-}" = -p ] || exit 65\n'
            '[ "$STUB_SPARKLE_KEY_OK" = 1 ] || exit 1\n'
            "printf 'public-key-placeholder\\n'",
        )
        self._write_executable(
            self.sparkle / "sign_update",
            textwrap.dedent(
                """
                file=''
                key_file=''
                verify=0
                if [ "${1:-}" = "--help" ]; then
                  [ "$STUB_SPARKLE_HELP_OK" = 1 ]
                  exit
                fi
                previous=''
                for arg in "$@"; do
                  [ "$arg" = "--verify" ] && verify=1
                  [ "$previous" = "--ed-key-file" ] && key_file="$arg"
                  [ -f "$arg" ] && file="$arg"
                  previous="$arg"
                done
                [ -z "$key_file" ] || [ -f "$key_file" ] || exit 1
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

    def sentinel_snapshot(self):
        snapshot = []
        paths = (self.sentinel_root, *sorted(self.sentinel_root.rglob("*")))
        for path in paths:
            metadata = path.lstat()
            relative = (
                "."
                if path == self.sentinel_root
                else str(path.relative_to(self.sentinel_root))
            )
            if path.is_symlink():
                payload = ("symlink", os.readlink(path))
            elif path.is_file():
                payload = ("file", path.read_bytes())
            else:
                payload = ("directory", None)
            snapshot.append(
                (
                    relative,
                    stat.S_IMODE(metadata.st_mode),
                    metadata.st_mtime_ns,
                    payload,
                )
            )
        return snapshot

    def run_doctor(
        self,
        *,
        mode: str = "package",
        env: dict[str, str] | None = None,
        extra=(),
        cwd: Path = ROOT,
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
        sentinel_before = self.sentinel_snapshot()
        result = subprocess.run(
            command,
            cwd=cwd,
            env=env or self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )
        if result.returncode != 0:
            self.case.assertEqual(self.sentinel_snapshot(), sentinel_before)
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

    def test_deployment_inspection_cannot_mutate_package_lock_state(self):
        lock_sentinel = self.fx.root / "workspace-Package.resolved"
        lock_sentinel.write_text("original\n", encoding="utf-8")
        env = {
            **self.fx.env,
            "STUB_PACKAGE_LOCK_SENTINEL": str(lock_sentinel),
        }

        result = self.fx.run_doctor(env=env)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(lock_sentinel.read_text(encoding="utf-8"), "original\n")

    def test_rejects_insufficient_disk_space(self):
        env = {**self.fx.env, "STUB_DISK_AVAILABLE_KB": str(2 * 1024 * 1024)}
        self.assert_failure("free disk", env=env)

    def test_rejects_unwritable_deterministic_scratch_root(self):
        blocked = self.fx.root / "not-a-directory"
        blocked.write_text("blocked", encoding="utf-8")
        env = {**self.fx.env, "LUNGFISH_RELEASE_SCRATCH_ROOT": str(blocked)}
        self.assert_failure("scratch root", env=env)

    def test_rejects_repository_home_and_existing_release_output_as_scratch(self):
        home = self.fx.root / "home"
        home.mkdir()
        empty_release_output = self.fx.root / "empty-release-output"
        empty_release_output.mkdir()
        for scratch in (ROOT, home, self.fx.sentinel_root, empty_release_output):
            with self.subTest(scratch=scratch):
                before = self.fx.sentinel_snapshot()
                env = {
                    **self.fx.env,
                    "HOME": str(home),
                    "LUNGFISH_RELEASE_SCRATCH_ROOT": str(scratch),
                }
                result = self.fx.run_doctor(env=env)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("scratch root", result.stdout + result.stderr)
                self.assertEqual(self.fx.sentinel_snapshot(), before)

    def test_earlier_failure_does_not_create_scratch_or_resolver_cache(self):
        scratch = self.fx.root / "must-not-be-created"
        env = {
            **self.fx.env,
            "DEVELOPER_DIR": str(self.fx.root / "missing-xcode"),
            "LUNGFISH_RELEASE_SCRATCH_ROOT": str(scratch),
        }
        env.pop("LUNGFISH_SPARKLE_TOOLS_DIR")
        result = self.fx.run_doctor(env=env)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Xcode selection", result.stdout + result.stderr)
        self.assertFalse(scratch.exists())

    def test_accepts_existing_pin_keyed_resolver_cache_as_scratch(self):
        user_root = self.fx.scratch / f"uid-{os.geteuid()}"
        cache = user_root / "sparkle-tools" / ("a" * 64)
        cache.mkdir(parents=True)
        self.fx.scratch.chmod(0o700)
        user_root.chmod(0o700)
        result = self.fx.run_doctor()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS scratch root", result.stdout)

    def test_accepts_framework_symlinks_inside_pin_keyed_resolver_build(self):
        user_root = self.fx.scratch / f"uid-{os.geteuid()}"
        framework = (
            user_root
            / "sparkle-tools"
            / ("a" * 64)
            / "build/artifacts/sparkle/Sparkle/Sparkle.framework"
        )
        (framework / "Versions/B/Resources").mkdir(parents=True)
        (framework / "Versions/Current").symlink_to("B")
        (framework / "Resources").symlink_to("Versions/Current/Resources")
        self.fx.scratch.chmod(0o700)
        user_root.chmod(0o700)

        result = self.fx.run_doctor()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS scratch root", result.stdout)

    def test_accepts_existing_deterministic_package_scratch_as_scratch(self):
        package_scratch = self.fx.scratch / ("b" * 64) / ("c" * 40)
        package_scratch.mkdir(parents=True)
        self.fx.scratch.chmod(0o700)

        result = self.fx.run_doctor()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS scratch root", result.stdout)

    def test_accepts_swiftpm_symlinks_below_private_package_scratch_identity(self):
        package_scratch = self.fx.scratch / ("b" * 64) / ("c" * 40)
        checkout = package_scratch / "checkouts/dependency/Sources"
        checkout.mkdir(parents=True)
        (checkout / "Real.swift").write_text("// fixture\n")
        (checkout / "Linked.swift").symlink_to("Real.swift")
        self.fx.scratch.chmod(0o700)

        result = self.fx.run_doctor()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS scratch root", result.stdout)

    def test_rejects_group_or_other_writable_scratch_cache(self):
        user_root = self.fx.scratch / f"uid-{os.geteuid()}"
        cache = user_root / "sparkle-tools" / ("a" * 64)
        cache.mkdir(parents=True)
        self.fx.scratch.chmod(0o700)
        user_root.chmod(0o770)
        result = self.fx.run_doctor()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("permissions", result.stdout + result.stderr)

    def test_rejects_symlinked_scratch_cache_component(self):
        outside = self.fx.root / "outside-sparkle-tools"
        (outside / ("a" * 64)).mkdir(parents=True)
        user_root = self.fx.scratch / f"uid-{os.geteuid()}"
        user_root.mkdir(parents=True, mode=0o700)
        self.fx.scratch.chmod(0o700)
        (user_root / "sparkle-tools").symlink_to(outside)
        result = self.fx.run_doctor()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("symlink", result.stdout + result.stderr)

    def test_cache_metadata_boundary_rejects_foreign_owner_uid(self):
        sys.path.insert(0, str(DOCTOR.parent))
        try:
            spec = importlib.util.spec_from_file_location("release_doctor_test", DOCTOR)
            self.assertIsNotNone(spec)
            self.assertIsNotNone(spec.loader)
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module
            try:
                spec.loader.exec_module(module)
            finally:
                sys.modules.pop(spec.name, None)
        finally:
            sys.path.pop(0)
        self.assertTrue(
            hasattr(module.Doctor, "_validate_cache_metadata"),
            "Doctor must expose the ownership/mode validation boundary",
        )
        metadata = SimpleNamespace(
            st_uid=os.getuid() + 1,
            st_mode=stat.S_IFDIR | 0o700,
        )
        with self.assertRaises(module.CheckFailure):
            module.Doctor._validate_cache_metadata(
                metadata, expected_uid=os.getuid(), require_private=True
            )

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

    def test_rejects_read_only_github_release_permission(self):
        env = {**self.fx.env, "STUB_GH_CAN_PUSH": "false"}
        self.assert_failure("GitHub release permission", mode="credentials", env=env)

    def test_rejects_missing_sparkle_tools(self):
        missing = self.fx.root / "missing-sparkle-tools"
        env = {**self.fx.env, "LUNGFISH_SPARKLE_TOOLS_DIR": str(missing)}
        self.assert_failure("Sparkle tools", env=env)

    def test_rejects_unusable_sparkle_tool_executables(self):
        env = {**self.fx.env, "STUB_SPARKLE_HELP_OK": "0"}
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

    def test_json_report_refuses_symlink_without_modifying_target(self):
        target = self.fx.root / "must-not-change.txt"
        target.write_text("preserve me\n", encoding="utf-8")
        target.chmod(0o640)
        report = self.fx.root / "doctor-link.json"
        report.symlink_to(target)
        before = (target.read_bytes(), stat.S_IMODE(target.stat().st_mode))
        result = self.fx.run_doctor(extra=("--json-report", str(report)))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("JSON report", result.stdout + result.stderr)
        self.assertTrue(report.is_symlink())
        self.assertEqual(
            (target.read_bytes(), stat.S_IMODE(target.stat().st_mode)), before
        )

    def test_relative_private_key_is_resolved_from_invocation_directory(self):
        caller = self.fx.root / "caller"
        caller.mkdir()
        key = caller / "relative-private-key"
        key.write_text("private-key-material", encoding="utf-8")
        key.chmod(0o600)
        result = self.fx.run_doctor(
            mode="credentials",
            cwd=caller,
            extra=("--sparkle-ed-key-file", key.name),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS Sparkle sign/verify probe", result.stdout)


class SparkleResolverTests(unittest.TestCase):
    def _copy_resolver_repo(self, root: Path) -> tuple[Path, Path]:
        repo = root / "repo"
        release_scripts = repo / "scripts" / "release"
        release_scripts.mkdir(parents=True)
        resolver = release_scripts / "resolve-sparkle-tools.sh"
        shutil.copy2(RESOLVER, resolver)
        shutil.copy2(
            ROOT / "scripts" / "release" / "release_cache_security.py",
            release_scripts / "release_cache_security.py",
        )
        shutil.copy2(ROOT / "Package.swift", repo / "Package.swift")
        shutil.copy2(ROOT / "Package.resolved", repo / "Package.resolved")
        return repo, resolver

    def _preseed_both_cache_layouts(
        self, repo: Path, scratch: Path
    ) -> tuple[Path, Path]:
        lock_hash = resolved_lock_hash(repo / "Package.resolved")
        suffix = (
            Path("sparkle-tools")
            / lock_hash
            / "build"
            / "artifacts"
            / "sparkle"
            / "Sparkle"
            / "bin"
        )
        old_tools = scratch / suffix
        user_tools = scratch / f"uid-{os.getuid()}" / suffix
        write_tool_trio(old_tools)
        write_tool_trio(user_tools)
        scratch.chmod(0o700)
        (scratch / f"uid-{os.getuid()}").chmod(0o700)
        return old_tools, user_tools

    def _run_resolver_with_xcrun_probe(
        self, repo: Path, resolver: Path, scratch: Path, temp_root: Path
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        bin_dir = temp_root / "probe-bin"
        bin_dir.mkdir()
        invoked = temp_root / "xcrun-invoked"
        xcrun = bin_dir / "xcrun"
        xcrun.write_text(
            '#!/bin/bash\nset -eu\ntouch "$STUB_XCRUN_SENTINEL"\nexit 99\n',
            encoding="utf-8",
        )
        xcrun.chmod(0o755)
        result = subprocess.run(
            ["/bin/bash", str(resolver)],
            cwd=repo,
            env={
                **os.environ,
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "LUNGFISH_RELEASE_SCRATCH_ROOT": str(scratch),
                "STUB_XCRUN_SENTINEL": str(invoked),
            },
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        return result, invoked

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
            temp_root = Path(temp).resolve()
            repo = temp_root / "repo"
            release_scripts = repo / "scripts" / "release"
            release_scripts.mkdir(parents=True)
            resolver = release_scripts / "resolve-sparkle-tools.sh"
            shutil.copy2(RESOLVER, resolver)
            shutil.copy2(
                ROOT / "scripts" / "release" / "release_cache_security.py",
                release_scripts / "release_cache_security.py",
            )
            stale_tools = repo / ".build" / "artifacts" / "sparkle" / "Sparkle" / "bin"
            stale_tools.mkdir(parents=True)
            for name in ("generate_appcast", "sign_update", "generate_keys"):
                stale = stale_tools / name
                stale.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
                stale.chmod(0o755)
            (repo / "Package.swift").write_text(
                "// swift-tools-version: 6.2\nORIGINAL_MANIFEST_SENTINEL\n",
                encoding="utf-8",
            )
            shutil.copy2(ROOT / "Package.resolved", repo / "Package.resolved")
            before = (repo / "Package.resolved").read_bytes()
            bin_dir = temp_root / "bin"
            bin_dir.mkdir()
            manifest_log = temp_root / "resolved-manifest.txt"
            resolved_log = temp_root / "resolved-lock.json"
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
                    "LUNGFISH_RELEASE_SCRATCH_ROOT": str(temp_root / "scratch"),
                    "STUB_MANIFEST_LOG": str(manifest_log),
                    "STUB_RESOLVED_LOG": str(resolved_log),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn(str(stale_tools), result.stdout)
            self.assertIn(f"/uid-{os.getuid()}/", result.stdout)
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
                    "LUNGFISH_RELEASE_SCRATCH_ROOT": str(temp_root / "scratch"),
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

    def test_resolver_rejects_preseeded_tools_without_private_provenance(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_root = Path(temp).resolve()
            repo, resolver = self._copy_resolver_repo(temp_root)
            scratch = temp_root / "scratch"
            old_tools, user_tools = self._preseed_both_cache_layouts(repo, scratch)
            executed = temp_root / "preseeded-executed"
            for directory in (old_tools, user_tools):
                write_tool_trio(directory, f'touch "{executed}"; exit 0')
            result = subprocess.run(
                ["/bin/bash", str(resolver)],
                cwd=repo,
                env={
                    **os.environ,
                    "LUNGFISH_RELEASE_SCRATCH_ROOT": str(scratch),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("provenance", result.stderr)
            self.assertFalse(executed.exists())

    def test_resolver_rejects_group_or_other_writable_user_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_root = Path(temp).resolve()
            repo, resolver = self._copy_resolver_repo(temp_root)
            scratch = temp_root / "scratch"
            self._preseed_both_cache_layouts(repo, scratch)
            (scratch / f"uid-{os.getuid()}").chmod(0o770)
            result = subprocess.run(
                ["/bin/bash", str(resolver)],
                cwd=repo,
                env={
                    **os.environ,
                    "LUNGFISH_RELEASE_SCRATCH_ROOT": str(scratch),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("permissions", result.stderr)

    def test_resolver_rejects_symlinked_cache_components(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_root = Path(temp).resolve()
            repo, resolver = self._copy_resolver_repo(temp_root)
            scratch = temp_root / "scratch"
            lock_hash = resolved_lock_hash(repo / "Package.resolved")
            outside = temp_root / "outside-build"
            write_tool_trio(outside / "artifacts" / "sparkle" / "Sparkle" / "bin")
            for root in (
                scratch / "sparkle-tools" / lock_hash,
                scratch / f"uid-{os.getuid()}" / "sparkle-tools" / lock_hash,
            ):
                root.mkdir(parents=True)
                (root / "build").symlink_to(outside)
            scratch.chmod(0o700)
            (scratch / f"uid-{os.getuid()}").chmod(0o700)
            result = subprocess.run(
                ["/bin/bash", str(resolver)],
                cwd=repo,
                env={
                    **os.environ,
                    "LUNGFISH_RELEASE_SCRATCH_ROOT": str(scratch),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("symlink", result.stderr)

    def test_resolver_rejects_nonsticky_writable_scratch_ancestor(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_root = Path(temp).resolve()
            repo, resolver = self._copy_resolver_repo(temp_root)
            unsafe_parent = temp_root / "unsafe-parent"
            unsafe_parent.mkdir()
            unsafe_parent.chmod(0o777)
            result, invoked = self._run_resolver_with_xcrun_probe(
                repo, resolver, unsafe_parent / "scratch", temp_root
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("unsafe ancestor", result.stderr)
            self.assertFalse(invoked.exists())

    def test_resolver_rejects_symlink_in_scratch_ancestor_chain(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_root = Path(temp).resolve()
            repo, resolver = self._copy_resolver_repo(temp_root)
            real_parent = temp_root / "real-parent"
            real_parent.mkdir()
            linked_parent = temp_root / "linked-parent"
            linked_parent.symlink_to(real_parent)
            result, invoked = self._run_resolver_with_xcrun_probe(
                repo, resolver, linked_parent / "scratch", temp_root
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("symlink", result.stderr)
            self.assertFalse(invoked.exists())

    def test_ancestor_metadata_boundary_rejects_foreign_owner(self):
        helper = ROOT / "scripts" / "release" / "release_cache_security.py"
        spec = importlib.util.spec_from_file_location("release_cache_test", helper)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(
            hasattr(module, "validate_ancestor_metadata"),
            "cache helper must expose the ancestor ownership boundary",
        )
        metadata = SimpleNamespace(
            st_uid=os.geteuid() + 1,
            st_mode=stat.S_IFDIR | 0o755,
        )
        with self.assertRaises(module.CacheSecurityError):
            module.validate_ancestor_metadata(metadata, expected_uid=os.geteuid())

    def test_default_private_var_tmp_ancestor_chain_is_accepted(self):
        helper = ROOT / "scripts" / "release" / "release_cache_security.py"
        spec = importlib.util.spec_from_file_location(
            "release_cache_default_test", helper
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(
            hasattr(module, "validate_ancestor_chain"),
            "cache helper must validate the full ancestor chain",
        )
        module.validate_ancestor_chain(
            Path("/private/var/tmp"), expected_uid=os.geteuid()
        )


class NightlyReleaseProfileTests(unittest.TestCase):
    def test_wrapper_never_consumes_preseeded_unproven_cache_tools(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_root = Path(temp).resolve()
            home = temp_root / "home"
            home.mkdir()
            bin_dir = temp_root / "bin"
            bin_dir.mkdir()
            captured = temp_root / "args.json"
            python_stub = bin_dir / "python3"
            python_stub.write_text(
                "#!/usr/bin/python3\nimport json, os, sys\n"
                "open(os.environ['CAPTURE_ARGS'], 'w').write(json.dumps(sys.argv[1:]))\n",
                encoding="utf-8",
            )
            python_stub.chmod(0o755)

            scratch = temp_root / "scratch"
            lock_hash = resolved_lock_hash(ROOT / "Package.resolved")
            suffix = (
                Path("sparkle-tools")
                / lock_hash
                / "build"
                / "artifacts"
                / "sparkle"
                / "Sparkle"
                / "bin"
            )
            write_tool_trio(scratch / suffix)
            write_tool_trio(scratch / f"uid-{os.getuid()}" / suffix)
            scratch.chmod(0o700)
            (scratch / f"uid-{os.getuid()}").chmod(0o700)
            env = {
                **os.environ,
                "HOME": str(home),
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "CAPTURE_ARGS": str(captured),
                "LUNGFISH_RELEASE_SCRATCH_ROOT": str(scratch),
            }
            env.pop("LUNGFISH_SPARKLE_TOOLS_DIR", None)
            result = subprocess.run(
                ["/bin/bash", str(NIGHTLY)],
                cwd=ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("provenance", result.stderr)
            self.assertFalse(captured.exists())

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
