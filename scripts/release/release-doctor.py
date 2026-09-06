#!/usr/bin/env python3
"""Validate a Lungfish release machine before packaging or publication."""

from __future__ import annotations

import argparse
import base64
import hashlib
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Callable

from release_cache_security import (
    CacheSecurityError,
    validate_ancestor_chain,
    validate_metadata,
)
from release_contract import CONTRACT_PATH, load_contract
from release_cache_fingerprint import (
    CacheFingerprintError,
    CachePaths,
    cache_paths,
    collect_fingerprint_document,
)
from release_repository import (
    RepositoryIdentity,
    RepositoryIdentityError,
    repository_identity_from_endpoints,
)
from release_target_security import TargetSecurityError, validate_release_targets
from release_xcode import XcodeSelectionError, resolve_developer_dir
from bounded_process import run_bounded
from credential_readiness import ReadinessError, setup_binding, require_setup_receipt, write_setup_receipt, begin_setup
from release_profiles import ProfileError
from release_identity import prepare_identity_plist


ROOT = Path(__file__).resolve().parents[2]
RESOLVER = ROOT / "scripts" / "release" / "resolve-sparkle-tools.sh"
LOCK_CHECK = ROOT / "scripts" / "check-package-resolved-consistency.sh"
DEFAULT_SCRATCH_ROOT = Path("/private/var/tmp/lungfish-release-swiftpm")
DEFAULT_CACHE_ROOT = Path("/private/var/tmp/lungfish-release-cache")
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
        self.environment.pop("GH_HOST", None)
        self.results: list[CheckResult] = []
        self.developer_dir: Path | None = None
        self.sparkle_tools: dict[str, Path] = {}
        self.repository_identity: RepositoryIdentity | None = None
        self.cache: CachePaths | None = None

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
            result = run_bounded(command, cwd=cwd, env=self.environment,
                                 timeout=COMMAND_TIMEOUT_SECONDS)
            if result.timed_out:
                raise CheckFailure("required command exceeded its time budget; child process group terminated")
            return result
        except OSError as error:
            raise CheckFailure("required command could not be executed") from error

    def _select_xcode(self) -> str:
        try:
            self.developer_dir = resolve_developer_dir(self.environment)
        except XcodeSelectionError as error:
            raise CheckFailure(str(error)) from error
        self.environment["DEVELOPER_DIR"] = str(self.developer_dir)
        return "full Xcode developer directory selected"

    def _required_commands(self) -> str:
        names = [
            "bash", "df", "ditto", "git", "mktemp", "plutil",
            "uname", "xcodebuild", "xcrun",
        ]
        if self.args.mode == "credentials":
            names.extend(["gh", "security", "codesign"])
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

    def _python_version(self) -> str:
        if sys.version_info < (3, 11):
            raise CheckFailure("Python 3.11 or newer is required")
        return f"Python {sys.version_info.major}.{sys.version_info.minor} is supported"

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
        build = re.search(r"^Build version\s+(\S+)\s*$", result.stdout, re.MULTILINE)
        if build is None:
            raise CheckFailure("could not parse Xcode build identity")
        if not self._version_in_range(
            observed, self.toolchain.xcodeMinimum, self.toolchain.xcodeMaximumExclusive
        ):
            raise CheckFailure(
                f"observed version is outside [{self.toolchain.xcodeMinimum}, "
                f"{self.toolchain.xcodeMaximumExclusive})"
            )
        return (
            f"Xcode {'.'.join(map(str, observed))} build {build.group(1)} "
            "is within the contract range"
        )

    def _xcode_first_launch(self) -> str:
        result = self.run_command(["xcodebuild", "-checkFirstLaunchStatus"])
        if result.returncode != 0:
            raise CheckFailure(
                "Xcode first-launch setup is incomplete; run the Apple-provided setup before releasing"
            )
        return "Xcode first-launch setup is complete"

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
        return f"Swift {'.'.join(map(str, observed))} is within the contract range"

    def _sdk_version(self) -> str:
        result = self.run_command(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
        if result.returncode != 0:
            raise CheckFailure("selected Xcode could not report the macOS SDK")
        observed = self._version_tuple(result.stdout, "macOS SDK version")
        if observed[0] != self.toolchain.sdkMajor:
            raise CheckFailure(f"expected SDK major {self.toolchain.sdkMajor}")
        build = self.run_command(
            ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]
        )
        if build.returncode != 0 or not build.stdout.strip():
            raise CheckFailure("selected Xcode could not report the macOS SDK build")
        return (
            f"macOS SDK {'.'.join(map(str, observed))} "
            f"build {build.stdout.strip()} is selected"
        )

    def _cache_root_path(self) -> Path:
        raw = self.args.cache_root or Path(
            self.environment.get("LUNGFISH_RELEASE_CACHE_ROOT", str(DEFAULT_CACHE_ROOT))
        )
        root = raw.expanduser()
        if not root.is_absolute():
            raise CheckFailure("release cache root must be absolute")
        return Path(os.path.abspath(root))

    def _cache_identity(self) -> str:
        identity = self._selected_repository_identity()
        try:
            document = collect_fingerprint_document(
                project_root=ROOT,
                repository=f"github.com/{identity.github_repository}",
                repository_key=identity.repository_key,
                deployment_target=self.toolchain.deploymentTarget,
                cli_info_plist=prepare_identity_plist(ROOT, self.contract, self.args.channel),
                command_output=lambda command: self._checked_output(command),
            )
            selected = cache_paths(
                self._cache_root_path(), identity.repository_key, document
            )
        except CacheFingerprintError as error:
            raise CheckFailure(str(error)) from error
        if (
            self.args.cache_fingerprint
            and self.args.cache_fingerprint != selected.fingerprint
        ):
            raise CheckFailure("cache fingerprint does not match the selected compiler recipe")
        if self.args.scratch_path and self.args.scratch_path != selected.swiftpm:
            raise CheckFailure("SwiftPM scratch path does not match the cache fingerprint")
        if (
            self.args.derived_data_path
            and self.args.derived_data_path != selected.derived_data
        ):
            raise CheckFailure("DerivedData path does not match the cache fingerprint")
        self.cache = selected
        return "canonical compiler-cache fingerprint matches the selected toolchain and recipe"

    def _checked_output(self, command: list[str]) -> str:
        result = self.run_command(command)
        if result.returncode != 0 or not result.stdout.strip():
            raise CacheFingerprintError("compiler identity command failed")
        return result.stdout

    def _cache_root_write(self) -> str:
        root = self._cache_root_path()
        repository = ROOT.resolve()
        home = Path(self.environment.get("HOME", str(Path.home()))).resolve(
            strict=False
        )
        if (
            root == repository
            or repository in root.parents
            or root == home
            or home in root.parents
        ):
            raise CheckFailure("release cache root must be outside the repository and home")
        existed = root.exists()
        probe: Path | None = None
        try:
            validate_ancestor_chain(root, expected_uid=os.geteuid())
            if not existed:
                root.mkdir(mode=0o700)
            self._validate_cache_metadata(
                root.lstat(), expected_uid=os.geteuid(), require_private=True
            )
            descriptor, raw = tempfile.mkstemp(prefix=".doctor-cache-probe-", dir=root)
            probe = Path(raw)
            with os.fdopen(descriptor, "wb") as handle:
                os.fchmod(handle.fileno(), 0o600)
                handle.write(b"lungfish-release-doctor\n")
                handle.flush()
                os.fsync(handle.fileno())
        except (CacheSecurityError, OSError) as error:
            raise CheckFailure("private release cache root is unsafe or unwritable") from error
        finally:
            if probe is not None:
                probe.unlink(missing_ok=True)
            if not existed:
                try:
                    root.rmdir()
                except OSError:
                    pass
        return "private owner-only cache root accepts bounded disposable writes"

    def _host_architecture(self) -> str:
        result = self.run_command(["uname", "-m"])
        if (
            result.returncode != 0
            or result.stdout.strip() != self.toolchain.architecture
        ):
            raise CheckFailure(f"expected {self.toolchain.architecture} release host")
        return f"host is {self.toolchain.architecture}"

    def _deployment_target(self) -> str:
        project_file = ROOT / "Lungfish.xcodeproj" / "project.pbxproj"
        try:
            project = project_file.read_text(encoding="utf-8")
        except OSError as error:
            raise CheckFailure("could not inspect Xcode project build settings") from error
        return self._deployment_targets_from_project(
            project,
            expected=self.toolchain.deploymentTarget,
        )

    @staticmethod
    def _deployment_targets_from_project(project: str, *, expected: str) -> str:
        setting_pattern = re.compile(
            r'^[ \t]*(?:"MACOSX_DEPLOYMENT_TARGET(?:\[[^"\]\r\n]+\])?"'
            r'|MACOSX_DEPLOYMENT_TARGET(?:\[[^\]\r\n]+\])?)'
            r"\s*=\s*([^;\r\n]+);",
            re.MULTILINE,
        )
        targets = [
            value.strip().strip('"')
            for value in setting_pattern.findall(project)
        ]
        occurrence_count = project.count("MACOSX_DEPLOYMENT_TARGET")
        if not targets or len(targets) != occurrence_count:
            raise CheckFailure("project did not report MACOSX_DEPLOYMENT_TARGET")
        unexpected = sorted({value for value in targets if value != expected})
        if unexpected:
            raise CheckFailure(
                f"expected {expected} for every inspected target"
            )
        return f"all committed project build configurations use {expected}"

    @staticmethod
    def _validate_cache_metadata(
        metadata: os.stat_result,
        *,
        expected_uid: int,
        require_private: bool = False,
        require_directory: bool = True,
    ) -> None:
        try:
            validate_metadata(
                metadata,
                expected_uid=expected_uid,
                require_private=require_private,
                require_directory=require_directory,
            )
        except CacheSecurityError as error:
            raise CheckFailure(str(error)) from error

    def _scratch_base(self) -> Path:
        scratch = Path(
            self.environment.get(
                "LUNGFISH_RELEASE_SCRATCH_ROOT", str(DEFAULT_SCRATCH_ROOT)
            )
        ).expanduser()
        if not scratch.is_absolute():
            raise CheckFailure("deterministic scratch root must be absolute")
        try:
            validate_ancestor_chain(scratch, expected_uid=os.geteuid())
        except CacheSecurityError as error:
            raise CheckFailure(str(error)) from error
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
            if not entries:
                raise CheckFailure(
                    "existing scratch root is not owned by the Lungfish release cache"
                )
            try:
                self._validate_cache_metadata(
                    scratch.lstat(),
                    expected_uid=os.geteuid(),
                    require_private=True,
                )
            except CheckFailure as error:
                raise CheckFailure(f"scratch root is unsafe: {error}") from error
            for entry in entries:
                if entry.is_symlink() or not entry.is_dir():
                    raise CheckFailure("scratch cache contains an unsupported entry")
                if re.fullmatch(r"uid-[0-9]+", entry.name) is not None:
                    continue
                if re.fullmatch(r"[0-9a-f]{64}", entry.name) is None:
                    raise CheckFailure(
                        "existing scratch root is not owned by the Lungfish release cache"
                    )
                self._validate_package_scratch(entry)
        return scratch

    def _validate_package_scratch(self, repository_root: Path) -> None:
        self._validate_cache_metadata(
            repository_root.lstat(), expected_uid=os.geteuid()
        )
        try:
            commits = list(repository_root.iterdir())
        except OSError as error:
            raise CheckFailure("package scratch cache is unreadable") from error
        if not commits:
            raise CheckFailure("package scratch cache has no commit identity")
        for commit_root in commits:
            if (
                commit_root.is_symlink()
                or not commit_root.is_dir()
                or re.fullmatch(r"[0-9a-fA-F]{40}", commit_root.name) is None
            ):
                raise CheckFailure("package scratch cache identity is invalid")
            self._validate_cache_metadata(
                commit_root.lstat(), expected_uid=os.geteuid()
            )
            for directory, directory_names, file_names in os.walk(
                commit_root, followlinks=False
            ):
                for name in (*directory_names, *file_names):
                    path = Path(directory) / name
                    metadata = path.lstat()
                    if stat.S_ISLNK(metadata.st_mode):
                        # SwiftPM checkouts and binary frameworks legitimately
                        # contain source and framework-layout symlinks. They are
                        # safe below the private, owner-controlled repository
                        # and commit identity roots; never follow them here.
                        if metadata.st_uid != os.geteuid():
                            raise CheckFailure(
                                "package scratch cache contains a foreign-owned symlink"
                            )
                        continue
                    self._validate_cache_metadata(
                        metadata,
                        expected_uid=os.geteuid(),
                        require_directory=stat.S_ISDIR(metadata.st_mode),
                    )

    def _scratch_root(self) -> Path:
        scratch = self._scratch_base()
        user_root = scratch / f"uid-{os.geteuid()}"
        if not user_root.exists():
            return user_root
        if user_root.is_symlink():
            raise CheckFailure("scratch cache contains a symlink component")
        self._validate_cache_metadata(
            user_root.lstat(),
            expected_uid=os.geteuid(),
            require_private=True,
        )
        for directory, directory_names, file_names in os.walk(
            user_root, followlinks=False
        ):
            for name in (*directory_names, *file_names):
                path = Path(directory) / name
                metadata = path.lstat()
                if stat.S_ISLNK(metadata.st_mode):
                    relative_parts = path.relative_to(user_root).parts
                    if (
                        metadata.st_uid == os.geteuid()
                        and len(relative_parts) >= 4
                        and relative_parts[0] == "sparkle-tools"
                        and re.fullmatch(r"[0-9a-f]{64}", relative_parts[1]) is not None
                        and relative_parts[2] == "build"
                    ):
                        # SwiftPM binary artifacts contain conventional
                        # framework-layout symlinks. The private cache and
                        # pin-keyed resolution roots above remain non-symlink
                        # trust boundaries; do not follow build payload links.
                        continue
                    raise CheckFailure("scratch cache contains a symlink component")
                self._validate_cache_metadata(
                    metadata,
                    expected_uid=os.geteuid(),
                    require_directory=stat.S_ISDIR(metadata.st_mode),
                )
        return user_root

    def _disk_space(self) -> str:
        locations = (
            self._cache_root_path(),
            self.args.release_dir or ROOT / "build/Release",
        )
        required_kib = self.toolchain.minimumFreeDiskGiB * 1024 * 1024
        checked: set[str] = set()
        for location in locations:
            probe = location
            while not probe.exists() and probe != probe.parent:
                probe = probe.parent
            result = self.run_command(["df", "-Pk", str(probe)])
            if result.returncode != 0:
                raise CheckFailure("could not inspect free disk space")
            lines = [line for line in result.stdout.splitlines() if line.strip()]
            try:
                fields = lines[-1].split()
                available_kib = int(fields[3])
                volume = fields[-1]
            except (IndexError, ValueError) as error:
                raise CheckFailure("could not parse free disk space") from error
            if volume in checked:
                continue
            checked.add(volume)
            if available_kib < required_kib:
                raise CheckFailure(
                    f"at least {self.toolchain.minimumFreeDiskGiB} GiB is required on cache and output volumes"
                )
        return f"at least {self.toolchain.minimumFreeDiskGiB} GiB is available on cache and output volumes"

    def _mutation_targets(self) -> str:
        values = (
            self.args.scratch_path,
            self.args.release_dir,
            self.args.archive_path,
            self.args.derived_data_path,
        )
        if not any(values):
            return "no package mutation targets were requested"
        if not all(values):
            raise CheckFailure(
                "scratch, release, archive, and DerivedData targets must be supplied together"
            )

        repository_identity = self._selected_repository_identity()
        head = self.run_command(["git", "rev-parse", "--verify", "HEAD"])
        if head.returncode != 0:
            raise CheckFailure("could not derive commit scratch identity")
        try:
            validate_release_targets(
                project_root=ROOT,
                home=Path(pwd.getpwuid(os.geteuid()).pw_dir),
                scratch_root=self._cache_root_path(),
                scratch_path=self.args.scratch_path,
                release_dir=self.args.release_dir,
                archive_path=self.args.archive_path,
                derived_data_path=self.args.derived_data_path,
                repository_key=repository_identity.repository_key,
                commit=head.stdout.strip(),
            )
        except TargetSecurityError as error:
            raise CheckFailure(str(error)) from error
        return (
            "exact package mutation targets are canonical, private, and nonoverlapping"
        )

    def _selected_repository_identity(self) -> RepositoryIdentity:
        if self.repository_identity is not None:
            return self.repository_identity
        fetch = self.run_command(
            ["git", "remote", "get-url", "--all", self.args.remote]
        )
        push = self.run_command(
            ["git", "remote", "get-url", "--all", "--push", self.args.remote]
        )
        if (
            fetch.returncode != 0
            or push.returncode != 0
            or not fetch.stdout.strip()
            or not push.stdout.strip()
        ):
            raise CheckFailure("selected Git remote is unavailable")
        try:
            identity = repository_identity_from_endpoints(
                self.args.remote,
                [line for line in fetch.stdout.splitlines() if line.strip()],
                [line for line in push.stdout.splitlines() if line.strip()],
                self.args.github_repository,
            )
        except RepositoryIdentityError as error:
            raise CheckFailure(str(error)) from error
        self.repository_identity = identity
        self.environment["GH_REPO"] = f"github.com/{identity.github_repository}"
        return identity

    def _selected_repository(self) -> str:
        self._selected_repository_identity()
        return "selected Git remote is bound to one GitHub repository"

    def _scratch_write(self) -> str:
        scratch_base = self._scratch_base()
        base_existed = scratch_base.exists()
        scratch = self._scratch_root()
        created = False
        probe_path: Path | None = None
        try:
            if not scratch_base.exists():
                scratch_base.mkdir(parents=True, mode=0o700)
            try:
                validate_ancestor_chain(scratch_base, expected_uid=os.geteuid())
            except CacheSecurityError as error:
                raise CheckFailure(str(error)) from error
            if not scratch.exists():
                scratch.mkdir(mode=0o700)
                created = True
            self._validate_cache_metadata(
                scratch.lstat(),
                expected_uid=os.geteuid(),
                require_private=True,
            )
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
            if not base_existed:
                try:
                    scratch_base.rmdir()
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
        command = ["security", "find-identity", "-v", "-p", "codesigning"]
        if self.args.signing_keychain:
            command.append(str(self.args.signing_keychain))
        result = self.run_command(command)
        if result.returncode != 0 or f'"{self.signing_identity}"' not in result.stdout:
            raise CheckFailure("requested Developer ID signing identity is unavailable")
        if self.args.certificate_sha1:
            pattern = re.compile(r"\b" + re.escape(self.args.certificate_sha1) + r'\s+"' + re.escape(self.signing_identity) + r'"', re.IGNORECASE)
            if not pattern.search(result.stdout):
                raise CheckFailure("selected certificate fingerprint does not match the Developer ID identity")
        return "requested Developer ID signing identity is present; private-key use is checked separately"

    def _team_id(self) -> str:
        match = re.search(r"\(([A-Z0-9]+)\)\s*$", self.signing_identity)
        if match is None or match.group(1) != self.team_id:
            raise CheckFailure("Team ID does not match the Developer ID identity")
        return "Team ID matches the Developer ID identity"

    def _signing_probe(self) -> str:
        # Only disposable system bytes are signed. Setup permission is checked before this method.
        with tempfile.TemporaryDirectory(prefix="lungfish-signing-probe-") as directory:
            probe = Path(directory) / "probe"
            shutil.copyfile("/usr/bin/true", probe)
            probe.chmod(0o700)
            command = ["codesign", "--force", "--sign", self.args.certificate_sha1 or self.signing_identity,
                       "--options", "runtime", "--timestamp"]
            if self.args.signing_keychain:
                command += ["--keychain", str(self.args.signing_keychain)]
            signed = self.run_command([*command, str(probe)])
            if signed.returncode != 0:
                raise CheckFailure("disposable signing probe failed; selected private key is unavailable or requires setup")
            verified = self.run_command(["codesign", "--verify", "--strict", str(probe)])
            detail = self.run_command(["codesign", "--display", "--verbose=4", str(probe)])
            if verified.returncode != 0 or detail.returncode != 0 or f"TeamIdentifier={self.team_id}" not in (detail.stdout + detail.stderr).splitlines():
                raise CheckFailure("disposable signature verification or selected Team ID check failed")
        return "selected private key signed a disposable executable and its signature Team ID verified"

    def _notary(self) -> str:
        command = ["xcrun", "notarytool", "history", "--keychain-profile", self.notary_profile]
        if self.args.notary_keychain:
            command += ["--keychain", str(self.args.notary_keychain)]
        result = self.run_command(command)
        if result.returncode != 0:
            raise CheckFailure("notary profile is missing, locked, or unusable")
        return "notary profile credentials are usable now"

    def _github_auth(self) -> str:
        result = self.run_command(["gh", "auth", "status", "--hostname", "github.com"])
        if result.returncode != 0:
            raise CheckFailure("GitHub authentication is unavailable")
        return "GitHub authentication is usable"

    def _github_repository(self) -> str:
        identity = self._selected_repository_identity()
        result = self.run_command(
            [
                "gh",
                "api",
                "--hostname",
                "github.com",
                f"repos/{identity.github_repository}",
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

    def _expected_sparkle_key(self) -> str:
        value = self.args.sparkle_public_ed_key
        try:
            if not value or len(base64.b64decode(value, validate=True)) != 32:
                raise ValueError()
        except (ValueError, TypeError):
            raise CheckFailure("expected committed Sparkle public key is required and must encode 32 bytes")
        return value

    def _sparkle_key(self) -> str:
        expected = self._expected_sparkle_key()
        self.sparkle_key_file = None
        configured = self.args.sparkle_ed_key_file or self.environment.get("LUNGFISH_SPARKLE_ED_KEY_FILE")
        if configured:
            # Legacy internal helper only. Public machine profiles contain Keychain selectors.
            candidate = Path(configured).expanduser().absolute()
            try:
                metadata = candidate.lstat()
            except OSError as error:
                raise CheckFailure("Sparkle private key file is unavailable") from error
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 1:
                raise CheckFailure("Sparkle private key file must be an owned regular non-symlink mode-0600 file")
            self.sparkle_key_file = candidate
            return "legacy private key file configured; candidate public-key match requires the independent signature probe"
        generate_keys = self.sparkle_tools.get("SPARKLE_GENERATE_KEYS")
        if generate_keys is None:
            raise CheckFailure("Sparkle Keychain key cannot be checked without generate_keys")
        result = self.run_command([str(generate_keys), "--account", self.args.sparkle_account, "-p"])
        if result.returncode != 0:
            raise CheckFailure("Sparkle Keychain key is missing, locked, or inaccessible")
        if result.stdout.strip() != expected:
            raise CheckFailure("selected Sparkle account public key does not match the committed candidate public key")
        return "selected Sparkle account matches the committed public key"

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
            key_args = (["--ed-key-file", str(self.sparkle_key_file)] if self.sparkle_key_file is not None
                        else ["--account", self.args.sparkle_account])
            signed = self.run_command(
                [str(sign_update), *key_args, "-p", str(probe_path)]
            )
            signature = signed.stdout.strip()
            if signed.returncode != 0 or not signature:
                raise CheckFailure(
                    "Sparkle signing probe failed; unlock or restore the signing key"
                )
            verified = self.run_command(
                ["xcrun", "swift", str(ROOT / "scripts/release/verify-sparkle-signature.swift"),
                 self._expected_sparkle_key(), signature, str(probe_path)]
            )
            if verified.returncode != 0:
                raise CheckFailure("Sparkle signature verification probe failed")
        except OSError as error:
            raise CheckFailure("could not create disposable Sparkle probe") from error
        finally:
            if probe_path is not None:
                probe_path.unlink(missing_ok=True)
        return "disposable payload signed and independently verified against the committed public key"

    def _credential_setup_guard(self) -> str:
        # Check receipt presence before any credential-consuming tool invocation.
        if self.args.setup_receipt is None:
            raise CheckFailure("explicit credential setup receipt is required; timeout/closed stdin do not suppress macOS authorization dialogs")
        if self.args.credential_probe_mode == "unattended" and (self.args.sparkle_ed_key_file or self.environment.get("LUNGFISH_SPARKLE_ED_KEY_FILE")):
            raise CheckFailure("legacy key-file probes require explicit setup mode; unattended publication uses profile Keychain selectors")
        if self.args.credential_probe_mode == "unattended" and not self.args.setup_receipt.is_file():
            raise CheckFailure("credential setup is incomplete; run explicit setup before unattended credential access")
        boot = self.run_command(["sysctl", "-n", "kern.boottime"])
        if boot.returncode != 0 or not boot.stdout.strip():
            raise CheckFailure("could not bind credential readiness to this boot")
        repository_identity = self._selected_repository_identity()
        selectors = dict(repository=repository_identity.github_repository, repositoryKey=repository_identity.repository_key, signingIdentity=self.signing_identity,
                         teamId=self.team_id, signingKeychain=str(self.args.signing_keychain or ""),
                         certificateSha1=self.args.certificate_sha1, notaryProfile=self.notary_profile,
                         notaryKeychain=str(self.args.notary_keychain or ""), sparkleAccount=self.args.sparkle_account,
                         sparklePublicKey=self._expected_sparkle_key(), developerDir=str(self.developer_dir), uid=os.geteuid(),
                         host=os.uname().nodename,
                         legacyKeyFile=str(self.args.sparkle_ed_key_file or self.environment.get("LUNGFISH_SPARKLE_ED_KEY_FILE", "")))
        tools = dict(self.sparkle_tools)
        for name in ("codesign", "security", "gh", "xcrun"):
            path = shutil.which(name, path=self.environment.get("PATH"))
            if path is None: raise CheckFailure("credential readiness tool is missing")
            tools[name] = Path(path)
        if self.developer_dir is not None:
            tools["notarytool"] = self.developer_dir / "usr/bin/notarytool"
        tools["publicKeyVerifier"] = ROOT / "scripts/release/verify-sparkle-signature.swift"
        try:
            self.setup_binding = setup_binding(selectors, tools, boot.stdout.strip())
            if self.args.credential_probe_mode == "unattended":
                require_setup_receipt(self.args.setup_receipt, self.setup_binding)
            else:
                begin_setup(self.args.setup_receipt, self.setup_binding)
        except (ReadinessError, ProfileError, OSError) as error:
            raise CheckFailure(str(error)) from error
        return "explicit setup probes authorized" if self.args.credential_probe_mode == "setup" else "completed setup evidence matches tools, selectors and boot; OS authorization may still change"

    def _record_credential_setup(self) -> str:
        if self.args.credential_probe_mode == "setup":
            try:
                write_setup_receipt(self.args.setup_receipt, self.setup_binding)
            except (ReadinessError, ProfileError, OSError) as error:
                raise CheckFailure("credential probes passed but setup evidence could not be written") from error
        return "credential probes passed now; commands remain bounded because Keychain access can change"

    def run(self) -> bool:
        package_checks = (
            ("selected Git remote", self._selected_repository),
            ("Xcode selection", self._select_xcode),
            ("required commands", self._required_commands),
            ("Python version", self._python_version),
            ("Xcode version", self._xcode_version),
            ("Xcode first-launch", self._xcode_first_launch),
            ("Swift version", self._swift_version),
            ("macOS SDK", self._sdk_version),
            ("host architecture", self._host_architecture),
            ("project deployment target", self._deployment_target),
            ("mutation targets", self._mutation_targets),
            ("cache fingerprint", self._cache_identity),
            ("free disk", self._disk_space),
            ("release cache root", self._cache_root_write),
            ("scratch root", self._scratch_write),
            ("clean source tree", self._clean_tree),
            ("source HEAD", self._head),
            ("dependency lockfiles", self._lockfiles),
            ("Sparkle tools", self._resolve_sparkle_tools),
        )
        if self.args.mode == "credentials" and self.args.credential_probe_mode == "setup":
            # Credential provisioning does not build, package, or authorize a source tree.
            setup_checks = {"selected Git remote", "Xcode selection", "required commands",
                            "Python version", "Xcode version", "Xcode first-launch",
                            "Swift version", "macOS SDK", "host architecture", "Sparkle tools"}
            package_checks = tuple(check for check in package_checks if check[0] in setup_checks)
        for name, operation in package_checks:
            if not self.check(name, operation):
                return False

        if self.args.mode == "credentials":
            for name, operation in (("credential inputs", self._credential_inputs),
                                    ("credential setup", self._credential_setup_guard)):
                if not self.check(name, operation):
                    return False
            if self.args.credential_probe_mode == "unattended":
                self.results.append(CheckResult("unattended readiness", "PASS",
                    "completed explicit setup verified; no disposable credential probes repeated; production commands remain bounded and OS access can change"))
                return True
            credential_checks = (
                ("signing identity", self._signing_identity),
                ("Team ID", self._team_id),
                ("private signing key", self._signing_probe),
                ("notary profile", self._notary),
                ("GitHub authentication", self._github_auth),
                ("GitHub repository API", self._github_repository),
                ("Sparkle signing key", self._sparkle_key),
                ("Sparkle sign/verify probe", self._sparkle_probe),
                ("credential readiness", self._record_credential_setup),
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
    value.add_argument("--signing-keychain", type=Path)
    value.add_argument("--certificate-sha1")
    value.add_argument("--notary-keychain", type=Path)
    value.add_argument("--sparkle-account", default="ed25519")
    value.add_argument("--sparkle-public-ed-key")
    value.add_argument("--credential-probe-mode", choices=("setup", "unattended"), default="unattended")
    value.add_argument("--setup-receipt", type=Path)
    value.add_argument("--sparkle-ed-key-file", type=Path)
    value.add_argument("--remote", default="origin")
    value.add_argument("--github-repository")
    value.add_argument("--scratch-path", type=Path)
    value.add_argument("--release-dir", type=Path)
    value.add_argument("--archive-path", type=Path)
    value.add_argument("--derived-data-path", type=Path)
    value.add_argument("--cache-root", type=Path)
    value.add_argument("--cache-fingerprint")
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
