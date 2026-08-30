#!/usr/bin/env python3
"""Validate a Lungfish release machine before packaging or publication."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import tempfile
from typing import Callable

from release_contract import CONTRACT_PATH, load_contract


ROOT = Path(__file__).resolve().parents[2]
RESOLVER = ROOT / "scripts" / "release" / "resolve-sparkle-tools.sh"
LOCK_CHECK = ROOT / "scripts" / "check-package-resolved-consistency.sh"
DEFAULT_DEVELOPER_DIR = Path("/Applications/Xcode.app/Contents/Developer")
DEFAULT_SCRATCH_ROOT = Path("/private/var/tmp/lungfish-release-swiftpm")
COMMAND_TIMEOUT_SECONDS = 30


class CheckFailure(Exception):
    """An actionable, already-redacted preflight failure."""


@dataclass(frozen=True)
class CheckResult:
    name: str
    status: str
    detail: str


class Doctor:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.contract = load_contract(CONTRACT_PATH)
        self.toolchain = self.contract.toolchain
        self.environment = os.environ.copy()
        self.results: list[CheckResult] = []
        self.developer_dir: Path | None = None
        self.sparkle_tools: dict[str, Path] = {}

    def check(self, name: str, operation: Callable[[], str]) -> bool:
        try:
            detail = operation()
        except CheckFailure as error:
            self.results.append(CheckResult(name, "FAIL", str(error)))
            return False
        except Exception:
            self.results.append(
                CheckResult(name, "FAIL", "unexpected validation error")
            )
            return False
        self.results.append(CheckResult(name, "PASS", detail))
        return True

    def run_command(
        self, command: list[str], *, cwd: Path = ROOT
    ) -> subprocess.CompletedProcess[str]:
        try:
            return subprocess.run(
                command,
                cwd=cwd,
                env=self.environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=COMMAND_TIMEOUT_SECONDS,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise CheckFailure("required command could not be executed") from error

    def _select_xcode(self) -> str:
        configured = self.environment.get("DEVELOPER_DIR")
        if configured:
            candidate = Path(configured).expanduser()
        elif DEFAULT_DEVELOPER_DIR.is_dir():
            candidate = DEFAULT_DEVELOPER_DIR
        else:
            result = self.run_command(["xcode-select", "-p"])
            if result.returncode != 0 or not result.stdout.strip():
                raise CheckFailure(
                    "no full Xcode is selected; install Xcode or set DEVELOPER_DIR"
                )
            candidate = Path(result.stdout.strip())

        if "commandlinetools" in str(candidate).lower():
            raise CheckFailure(
                "CommandLineTools alone are unsupported; select full Xcode"
            )
        xcodebuild = candidate / "usr" / "bin" / "xcodebuild"
        if (
            not candidate.is_dir()
            or not xcodebuild.is_file()
            or not os.access(xcodebuild, os.X_OK)
        ):
            raise CheckFailure(
                "DEVELOPER_DIR does not identify a full Xcode installation"
            )

        self.developer_dir = candidate.resolve()
        self.environment["DEVELOPER_DIR"] = str(self.developer_dir)
        return "full Xcode developer directory selected"

    def _required_commands(self) -> str:
        names = ["df", "git", "uname", "xcodebuild", "xcrun"]
        if self.args.mode == "credentials":
            names.extend(["gh", "security"])
        missing = [
            name
            for name in names
            if shutil.which(name, path=self.environment.get("PATH")) is None
        ]
        if not RESOLVER.is_file() or not os.access(RESOLVER, os.X_OK):
            missing.append("resolve-sparkle-tools.sh")
        if missing:
            raise CheckFailure(
                "missing required commands: " + ", ".join(sorted(missing))
            )
        return "all required commands are available"

    @staticmethod
    def _version_tuple(raw: str, label: str) -> tuple[int, ...]:
        match = re.search(r"\d+(?:\.\d+)+", raw)
        if not match:
            raise CheckFailure(f"could not parse {label}")
        return tuple(int(part) for part in match.group(0).split("."))

    def _version_in_range(
        self, observed: tuple[int, ...], minimum: str, maximum: str
    ) -> bool:
        return (
            self._compare_versions(
                observed, self._version_tuple(minimum, "minimum version")
            )
            >= 0
            and self._compare_versions(
                observed, self._version_tuple(maximum, "maximum version")
            )
            < 0
        )

    @staticmethod
    def _compare_versions(left: tuple[int, ...], right: tuple[int, ...]) -> int:
        width = max(len(left), len(right))
        padded_left = left + (0,) * (width - len(left))
        padded_right = right + (0,) * (width - len(right))
        return (padded_left > padded_right) - (padded_left < padded_right)

    def _xcode_version(self) -> str:
        result = self.run_command(["xcodebuild", "-version"])
        if result.returncode != 0:
            raise CheckFailure("xcodebuild -version failed for the selected Xcode")
        observed = self._version_tuple(result.stdout, "Xcode version")
        if not self._version_in_range(
            observed, self.toolchain.xcodeMinimum, self.toolchain.xcodeMaximumExclusive
        ):
            raise CheckFailure(
                f"observed version is outside [{self.toolchain.xcodeMinimum}, "
                f"{self.toolchain.xcodeMaximumExclusive})"
            )
        return "observed version is within the contract range"

    def _swift_version(self) -> str:
        result = self.run_command(["xcrun", "swift", "--version"])
        if result.returncode != 0:
            raise CheckFailure("selected Xcode could not report Swift version")
        observed = self._version_tuple(result.stdout, "Swift version")
        if not self._version_in_range(
            observed, self.toolchain.swiftMinimum, self.toolchain.swiftMaximumExclusive
        ):
            raise CheckFailure(
                f"observed version is outside [{self.toolchain.swiftMinimum}, "
                f"{self.toolchain.swiftMaximumExclusive})"
            )
        return "observed version is within the contract range"

    def _sdk_version(self) -> str:
        result = self.run_command(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
        if result.returncode != 0:
            raise CheckFailure("selected Xcode could not report the macOS SDK")
        observed = self._version_tuple(result.stdout, "macOS SDK version")
        if observed[0] != self.toolchain.sdkMajor:
            raise CheckFailure(f"expected SDK major {self.toolchain.sdkMajor}")
        return f"SDK major {self.toolchain.sdkMajor} is selected"

    def _host_architecture(self) -> str:
        result = self.run_command(["uname", "-m"])
        if (
            result.returncode != 0
            or result.stdout.strip() != self.toolchain.architecture
        ):
            raise CheckFailure(f"expected {self.toolchain.architecture} release host")
        return f"host is {self.toolchain.architecture}"

    def _deployment_target(self) -> str:
        result = self.run_command(
            [
                "xcodebuild",
                "-project",
                str(ROOT / "Lungfish.xcodeproj"),
                "-scheme",
                "Lungfish",
                "-showBuildSettings",
            ]
        )
        if result.returncode != 0:
            raise CheckFailure("could not inspect Xcode project build settings")
        targets = re.findall(
            r"^\s*MACOSX_DEPLOYMENT_TARGET\s*=\s*(\S+)\s*$", result.stdout, re.MULTILINE
        )
        if not targets:
            raise CheckFailure("project did not report MACOSX_DEPLOYMENT_TARGET")
        unexpected = sorted(
            {value for value in targets if value != self.toolchain.deploymentTarget}
        )
        if unexpected:
            raise CheckFailure(
                f"expected {self.toolchain.deploymentTarget} for every inspected target"
            )
        return f"all inspected targets use {self.toolchain.deploymentTarget}"

    def _scratch_root(self) -> Path:
        scratch = Path(
            self.environment.get(
                "LUNGFISH_RELEASE_SCRATCH_ROOT", str(DEFAULT_SCRATCH_ROOT)
            )
        ).expanduser()
        if not scratch.is_absolute():
            raise CheckFailure("deterministic scratch root must be absolute")
        if scratch.is_symlink():
            raise CheckFailure("deterministic scratch root must not be a symlink")
        scratch = scratch.resolve(strict=False)
        repository = ROOT.resolve()
        home = Path(self.environment.get("HOME", str(Path.home()))).resolve(
            strict=False
        )
        if scratch == repository or repository in scratch.parents:
            raise CheckFailure("scratch root must be outside the repository")
        if scratch == home or home in scratch.parents:
            raise CheckFailure("scratch root must be outside the user home directory")
        if scratch.exists() and scratch.is_dir():
            entries = list(scratch.iterdir())
            cache_root = scratch / "sparkle-tools"
            cache_children = list(cache_root.iterdir()) if cache_root.is_dir() else []
            cache_shape_valid = (
                len(entries) == 1
                and entries[0] == cache_root
                and all(
                    child.is_dir()
                    and re.fullmatch(r"[0-9a-f]{64}", child.name) is not None
                    for child in cache_children
                )
            )
            if not entries or not cache_shape_valid:
                raise CheckFailure(
                    "existing scratch root is not owned by the Lungfish release cache"
                )
        return scratch

    def _disk_space(self) -> str:
        scratch = self._scratch_root()
        probe = scratch
        while not probe.exists() and probe != probe.parent:
            probe = probe.parent
        result = self.run_command(["df", "-Pk", str(probe)])
        if result.returncode != 0:
            raise CheckFailure("could not inspect free disk space")
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        try:
            available_kib = int(lines[-1].split()[3])
        except (IndexError, ValueError) as error:
            raise CheckFailure("could not parse free disk space") from error
        required_kib = self.toolchain.minimumFreeDiskGiB * 1024 * 1024
        if available_kib < required_kib:
            raise CheckFailure(
                f"at least {self.toolchain.minimumFreeDiskGiB} GiB is required"
            )
        return f"at least {self.toolchain.minimumFreeDiskGiB} GiB is available"

    def _scratch_write(self) -> str:
        scratch = self._scratch_root()
        created = False
        probe_path: Path | None = None
        try:
            if not scratch.exists():
                scratch.mkdir(parents=True)
                created = True
            if not scratch.is_dir():
                raise OSError("not a directory")
            descriptor, raw_path = tempfile.mkstemp(
                prefix=".doctor-write-probe-", dir=scratch
            )
            probe_path = Path(raw_path)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(b"lungfish-release-doctor\n")
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as error:
            raise CheckFailure("deterministic scratch root is not writable") from error
        finally:
            if probe_path is not None:
                probe_path.unlink(missing_ok=True)
            if created:
                try:
                    scratch.rmdir()
                except OSError:
                    pass
        return "deterministic scratch root accepts disposable writes"

    def _clean_tree(self) -> str:
        result = self.run_command(["git", "status", "--porcelain"])
        if result.returncode != 0:
            raise CheckFailure("could not inspect source tree")
        if result.stdout.strip():
            raise CheckFailure("source tree has tracked or untracked changes")
        return "source tree is clean"

    def _head(self) -> str:
        result = self.run_command(["git", "rev-parse", "--verify", "HEAD"])
        if (
            result.returncode != 0
            or re.fullmatch(r"[0-9a-fA-F]{40}", result.stdout.strip()) is None
        ):
            raise CheckFailure("repository has no valid HEAD commit")
        return "repository HEAD is valid"

    def _lockfiles(self) -> str:
        if not LOCK_CHECK.is_file():
            raise CheckFailure("lockfile consistency checker is missing")
        result = self.run_command(["/bin/bash", str(LOCK_CHECK), str(ROOT)])
        if result.returncode != 0:
            raise CheckFailure(
                "Package.resolved files or project requirements are inconsistent"
            )
        return "Package.resolved consistency check passed without repair"

    def _resolve_sparkle_tools(self) -> str:
        result = self.run_command(["/bin/bash", str(RESOLVER)])
        if result.returncode != 0:
            raise CheckFailure("could not resolve all pinned Sparkle tools")
        values: dict[str, Path] = {}
        try:
            assignments = shlex.split(result.stdout)
            for assignment in assignments:
                key, value = assignment.split("=", 1)
                values[key] = Path(value)
        except (ValueError, OSError) as error:
            raise CheckFailure(
                "resolver returned malformed Sparkle tool paths"
            ) from error
        required = {
            "SPARKLE_GENERATE_APPCAST",
            "SPARKLE_SIGN_UPDATE",
            "SPARKLE_GENERATE_KEYS",
        }
        if set(values) != required:
            raise CheckFailure(
                "resolver did not return exactly the required Sparkle tools"
            )
        if any(
            not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK)
            for path in values.values()
        ):
            raise CheckFailure(
                "resolved Sparkle tool paths are not executable absolute files"
            )
        for key in sorted(required):
            if self.run_command([str(values[key]), "--help"]).returncode != 0:
                raise CheckFailure("resolved Sparkle tools are not runnable")
        self.sparkle_tools = values
        return "generate_appcast, sign_update, and generate_keys are runnable"

    def _credential(
        self, flag_value: str | None, environment_name: str, label: str
    ) -> str:
        value = flag_value or self.environment.get(environment_name, "")
        if not value:
            raise CheckFailure(f"{label} is required in credentials mode")
        return value

    def _credential_inputs(self) -> str:
        self.signing_identity = self._credential(
            self.args.signing_identity, "LUNGFISH_SIGNING_IDENTITY", "signing identity"
        )
        self.team_id = self._credential(
            self.args.team_id, "LUNGFISH_TEAM_ID", "Team ID"
        )
        self.notary_profile = self._credential(
            self.args.notary_profile, "LUNGFISH_NOTARY_PROFILE", "notary profile"
        )
        if (
            "\n" in self.signing_identity
            or "\n" in self.team_id
            or "\n" in self.notary_profile
        ):
            raise CheckFailure("credential names must be one line")
        return "required credential names were provided"

    def _signing_identity(self) -> str:
        if not self.signing_identity.startswith("Developer ID Application:"):
            raise CheckFailure(
                "signing identity is not a Developer ID Application identity"
            )
        result = self.run_command(
            ["security", "find-identity", "-v", "-p", "codesigning"]
        )
        if result.returncode != 0 or f'"{self.signing_identity}"' not in result.stdout:
            raise CheckFailure("requested Developer ID signing identity is unavailable")
        return "requested Developer ID signing identity is usable"

    def _team_id(self) -> str:
        match = re.search(r"\(([A-Z0-9]+)\)\s*$", self.signing_identity)
        if match is None or match.group(1) != self.team_id:
            raise CheckFailure("Team ID does not match the Developer ID identity")
        return "Team ID matches the Developer ID identity"

    def _notary(self) -> str:
        result = self.run_command(
            [
                "xcrun",
                "notarytool",
                "history",
                "--keychain-profile",
                self.notary_profile,
            ]
        )
        if result.returncode != 0:
            raise CheckFailure("notary profile is missing, locked, or unusable")
        return "notary profile credentials are usable"

    def _github_auth(self) -> str:
        result = self.run_command(["gh", "auth", "status"])
        if result.returncode != 0:
            raise CheckFailure("GitHub authentication is unavailable")
        return "GitHub authentication is usable"

    def _github_repository(self) -> str:
        remote = self.run_command(["git", "remote", "get-url", "origin"])
        if remote.returncode != 0:
            raise CheckFailure("GitHub repository API target could not be derived")
        match = re.search(
            r"github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?\s*$", remote.stdout.strip()
        )
        if match is None:
            raise CheckFailure("GitHub repository API target could not be derived")
        result = self.run_command(
            [
                "gh",
                "api",
                f"repos/{match.group(1)}/{match.group(2)}",
                "--jq",
                ".permissions.push",
            ]
        )
        if result.returncode != 0:
            raise CheckFailure("GitHub repository API read failed")
        if result.stdout.strip() != "true":
            raise CheckFailure(
                "GitHub release permission is unavailable; repository write access is required"
            )
        return "GitHub repository API confirms release write permission"

    def _sparkle_key(self) -> str:
        configured = self.args.sparkle_ed_key_file or self.environment.get(
            "LUNGFISH_SPARKLE_ED_KEY_FILE"
        )
        self.sparkle_key_file: Path | None = None
        if configured:
            try:
                candidate = Path(configured).expanduser().resolve(strict=True)
                mode = stat.S_IMODE(candidate.stat().st_mode)
            except OSError as error:
                raise CheckFailure("Sparkle private key file is unavailable") from error
            if not candidate.is_file() or mode != 0o600:
                raise CheckFailure(
                    "Sparkle private key file must be a regular mode-0600 file"
                )
            self.sparkle_key_file = candidate
            return "explicit mode-0600 Sparkle private key file is usable"

        generate_keys = self.sparkle_tools.get("SPARKLE_GENERATE_KEYS")
        if generate_keys is None:
            raise CheckFailure(
                "Sparkle Keychain key cannot be checked without generate_keys"
            )
        result = self.run_command([str(generate_keys), "-p"])
        if result.returncode != 0 or not result.stdout.strip():
            raise CheckFailure(
                "Sparkle Keychain key is missing, locked, or inaccessible"
            )
        return "Sparkle Keychain key is accessible"

    def _sparkle_probe(self) -> str:
        sign_update = self.sparkle_tools.get("SPARKLE_SIGN_UPDATE")
        if sign_update is None:
            raise CheckFailure(
                "Sparkle sign/verify probe cannot run without sign_update"
            )
        probe_path: Path | None = None
        try:
            descriptor, raw_path = tempfile.mkstemp(prefix="lungfish-sparkle-probe-")
            probe_path = Path(raw_path)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(b"Lungfish disposable Sparkle signing probe\n")
                handle.flush()
                os.fsync(handle.fileno())
            key_args = (
                ["--ed-key-file", str(self.sparkle_key_file)]
                if self.sparkle_key_file is not None
                else []
            )
            signed = self.run_command(
                [str(sign_update), *key_args, "-p", str(probe_path)]
            )
            signature = signed.stdout.strip()
            if signed.returncode != 0 or not signature:
                raise CheckFailure(
                    "Sparkle signing probe failed; unlock or restore the signing key"
                )
            verified = self.run_command(
                [str(sign_update), *key_args, "--verify", str(probe_path), signature]
            )
            if verified.returncode != 0:
                raise CheckFailure("Sparkle signature verification probe failed")
        except OSError as error:
            raise CheckFailure("could not create disposable Sparkle probe") from error
        finally:
            if probe_path is not None:
                probe_path.unlink(missing_ok=True)
        return "disposable payload signed and verified"

    def run(self) -> bool:
        package_checks = (
            ("Xcode selection", self._select_xcode),
            ("required commands", self._required_commands),
            ("Xcode version", self._xcode_version),
            ("Swift version", self._swift_version),
            ("macOS SDK", self._sdk_version),
            ("host architecture", self._host_architecture),
            ("project deployment target", self._deployment_target),
            ("free disk", self._disk_space),
            ("scratch root", self._scratch_write),
            ("clean source tree", self._clean_tree),
            ("source HEAD", self._head),
            ("dependency lockfiles", self._lockfiles),
            ("Sparkle tools", self._resolve_sparkle_tools),
        )
        for name, operation in package_checks:
            if not self.check(name, operation):
                return False

        if self.args.mode == "credentials":
            credential_checks = (
                ("credential inputs", self._credential_inputs),
                ("signing identity", self._signing_identity),
                ("Team ID", self._team_id),
                ("notary profile", self._notary),
                ("GitHub authentication", self._github_auth),
                ("GitHub repository API", self._github_repository),
                ("Sparkle signing key", self._sparkle_key),
                ("Sparkle sign/verify probe", self._sparkle_probe),
            )
            for name, operation in credential_checks:
                if not self.check(name, operation):
                    return False

        return True

    def emit(self) -> None:
        for result in self.results:
            print(f"{result.status} {result.name}: {result.detail}")

    def write_json(self, path: Path, success: bool) -> None:
        payload = {
            "schemaVersion": 1,
            "mode": self.args.mode,
            "channel": self.args.channel,
            "success": success,
            "checks": [asdict(result) for result in self.results],
        }
        path = path.expanduser()
        if path.is_symlink():
            raise OSError("refusing to replace a symlink report path")
        temporary_path: Path | None = None
        try:
            descriptor, raw_temporary_path = tempfile.mkstemp(
                prefix=f".{path.name}.tmp-", dir=path.parent
            )
            temporary_path = Path(raw_temporary_path)
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                os.fchmod(handle.fileno(), 0o600)
                json.dump(payload, handle, sort_keys=True, indent=2)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            if path.is_symlink():
                raise OSError("refusing to replace a symlink report path")
            os.replace(temporary_path, path)
            temporary_path = None
        finally:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--mode", required=True, choices=("package", "credentials"))
    value.add_argument("--channel", required=True, choices=("preview", "stable"))
    value.add_argument("--signing-identity")
    value.add_argument("--team-id")
    value.add_argument("--notary-profile")
    value.add_argument("--sparkle-ed-key-file", type=Path)
    value.add_argument("--json-report", type=Path)
    return value


def main() -> int:
    args = parser().parse_args()
    try:
        doctor = Doctor(args)
    except ValueError as error:
        print(f"FAIL release contract: {error}")
        return 1
    success = doctor.run()
    doctor.emit()
    if args.json_report:
        try:
            doctor.write_json(args.json_report, success)
        except OSError:
            print("FAIL JSON report: could not write requested report")
            return 1
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
