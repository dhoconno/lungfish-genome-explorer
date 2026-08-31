#!/usr/bin/env python3
"""Derive and serialize one private Lungfish compiler-cache namespace."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import tempfile
import time
from typing import Any, Mapping, Sequence

try:
    from release_cache_security import CacheSecurityError, validate_ancestor_chain
except ModuleNotFoundError:  # Imported as scripts.release.* by the test suite.
    from scripts.release.release_cache_security import (
        CacheSecurityError,
        validate_ancestor_chain,
    )


HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")
BUILD_ENVIRONMENT = {
    "CC": "",
    "CXX": "",
    "SDKROOT": "",
    "SWIFT_EXEC": "",
    "TOOLCHAINS": "",
}
RECIPE_PATHS = (
    "Lungfish-Info.plist",
    "Lungfish.xcodeproj/project.pbxproj",
    "Package.swift",
    "lungfish-cli.entitlements",
    "scripts/bundle-native-tools.sh",
    "scripts/check-package-resolved-consistency.sh",
    "scripts/release/build-notarized-dmg.sh",
    "scripts/release/release-candidate-receipt.py",
    "scripts/release/release_cache_fingerprint.py",
    "scripts/release/scan-release-portability.py",
    "scripts/sanitize-bundled-tools.sh",
    "scripts/setup-worktree.sh",
    "scripts/smoke-test-release-tools.sh",
)
CACHE_MARKER = ".lungfish-release-cache.json"
CACHE_LOCK = ".build.lock"


class CacheFingerprintError(ValueError):
    """A compiler-cache identity is incomplete, malformed, or unsafe."""


@dataclass(frozen=True)
class CachePaths:
    fingerprint: str
    namespace: Path
    swiftpm: Path
    derived_data: Path
    lock: Path


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        + "\n"
    ).encode("utf-8")


def fingerprint(document: Mapping[str, Any]) -> str:
    return sha256_bytes(canonical_json_bytes(document))


def _require_hash(value: str, label: str) -> str:
    if HEX_SHA256.fullmatch(value) is None:
        raise CacheFingerprintError(f"{label} must be a lowercase SHA-256")
    return value


def _require_text(value: str, label: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise CacheFingerprintError(f"{label} must be nonempty text")
    return value


def build_fingerprint_document(
    *,
    repository: str,
    repository_key: str,
    xcode_version: str,
    xcode_build: str,
    swift_identity: str,
    sdk_version: str,
    sdk_build: str,
    architecture: str,
    deployment_target: str,
    configuration: str,
    products: Sequence[str],
    package_resolved_sha256: str,
    release_contract_sha256: str,
    recipe_hashes: Mapping[str, str],
) -> dict[str, Any]:
    """Return the complete path-independent v1 compiler-cache identity."""
    canonical_repository = _require_text(repository, "repository identity")
    if not canonical_repository.startswith("github.com/"):
        raise CacheFingerprintError("repository identity must be canonical github.com")
    normalized_products = sorted(
        {_require_text(product, "build product") for product in products}
    )
    if not normalized_products:
        raise CacheFingerprintError("at least one build product is required")
    normalized_recipe = {
        _require_text(path, "recipe path"): _require_hash(digest, "recipe hash")
        for path, digest in sorted(recipe_hashes.items())
    }
    if not normalized_recipe:
        raise CacheFingerprintError("recipe hash set must not be empty")
    swift_text = _require_text(swift_identity, "Swift compiler identity")
    return {
        "schemaVersion": 1,
        "repository": {
            "canonicalIdentity": canonical_repository,
            "key": _require_hash(repository_key, "repository key"),
        },
        "toolchain": {
            "architecture": _require_text(architecture, "architecture"),
            "sdk": {
                "build": _require_text(sdk_build, "SDK build"),
                "version": _require_text(sdk_version, "SDK version"),
            },
            "swift": {
                "identity": swift_text,
                "identitySha256": sha256_bytes(swift_text.encode("utf-8")),
            },
            "xcode": {
                "build": _require_text(xcode_build, "Xcode build"),
                "version": _require_text(xcode_version, "Xcode version"),
            },
        },
        "build": {
            "configuration": _require_text(configuration, "configuration"),
            "deploymentTarget": _require_text(
                deployment_target, "deployment target"
            ),
            "environment": dict(BUILD_ENVIRONMENT),
            "products": normalized_products,
            "recipe": {"files": normalized_recipe, "schemaVersion": 1},
        },
        "inputs": {
            "packageResolvedSha256": _require_hash(
                package_resolved_sha256, "Package.resolved hash"
            ),
            "releaseContractSha256": _require_hash(
                release_contract_sha256, "release contract hash"
            ),
        },
    }


def _hash_file(path: Path, label: str) -> str:
    try:
        metadata = path.lstat()
        if not path.is_file() or path.is_symlink():
            raise CacheFingerprintError(f"{label} must be a regular non-symlink file")
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise CacheFingerprintError(f"{label} is unavailable") from error
    if metadata.st_size != path.stat().st_size:
        raise CacheFingerprintError(f"{label} changed while hashing")
    return digest.hexdigest()


def _default_command_output(command: list[str]) -> str:
    try:
        result = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CacheFingerprintError("compiler identity command could not run") from error
    if result.returncode != 0 or not result.stdout.strip():
        raise CacheFingerprintError("compiler identity command failed")
    return result.stdout


def _xcode_identity(raw: str) -> tuple[str, str]:
    version = re.search(r"^Xcode\s+(\S+)\s*$", raw, re.MULTILINE)
    build = re.search(r"^Build version\s+(\S+)\s*$", raw, re.MULTILINE)
    if version is None or build is None:
        raise CacheFingerprintError("Xcode version/build identity is malformed")
    return version.group(1), build.group(1)


def collect_fingerprint_document(
    *,
    project_root: Path,
    repository: str,
    repository_key: str,
    deployment_target: str,
    command_output: Any = _default_command_output,
) -> dict[str, Any]:
    """Observe the selected compiler and hash the exact release recipe."""
    root = project_root.resolve(strict=True)
    recipe_hashes: dict[str, str] = {}
    for relative in RECIPE_PATHS:
        recipe_hashes[relative] = _hash_file(root / relative, "release recipe")
    xcode_version, xcode_build = _xcode_identity(
        command_output(["xcodebuild", "-version"])
    )
    swift_identity = command_output(["xcrun", "swift", "--version"]).strip()
    return build_fingerprint_document(
        repository=repository,
        repository_key=repository_key,
        xcode_version=xcode_version,
        xcode_build=xcode_build,
        swift_identity=swift_identity,
        sdk_version=command_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-version"]
        ).strip(),
        sdk_build=command_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]
        ).strip(),
        architecture=command_output(["uname", "-m"]).strip(),
        deployment_target=deployment_target,
        configuration="Release",
        products=("xcode:Lungfish", "swiftpm:lungfish-cli"),
        package_resolved_sha256=_hash_file(
            root / "Package.resolved", "Package.resolved"
        ),
        release_contract_sha256=_hash_file(
            root / "config/release-contract.json", "release contract"
        ),
        recipe_hashes=recipe_hashes,
    )


def _metadata(path: Path, uid: int, *, private_directory: bool = False) -> os.stat_result:
    try:
        value = path.lstat()
    except OSError as error:
        raise CacheFingerprintError("cache metadata is unavailable") from error
    if value.st_uid != uid:
        raise CacheFingerprintError("cache owner UID does not match the release user")
    if stat.S_ISLNK(value.st_mode):
        raise CacheFingerprintError("cache structural path is a symlink")
    if not stat.S_ISDIR(value.st_mode):
        raise CacheFingerprintError("cache structural path is not a directory")
    mode = stat.S_IMODE(value.st_mode)
    if mode & 0o022:
        raise CacheFingerprintError("cache permissions allow group or other writes")
    if private_directory and mode & 0o077:
        raise CacheFingerprintError("cache root permissions must be owner-only")
    return value


def _mkdir_private(path: Path, uid: int) -> None:
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        pass
    except OSError as error:
        raise CacheFingerprintError("private cache directory could not be created") from error
    _metadata(path, uid, private_directory=True)


def _validate_cache_entries(
    namespace: Path, uid: int, *, active_ready_file: Path | None = None
) -> None:
    root = namespace.resolve(strict=True)
    stack = [namespace]
    while stack:
        directory = stack.pop()
        try:
            entries = list(os.scandir(directory))
        except OSError as error:
            raise CacheFingerprintError("cache entries are unreadable") from error
        for entry in entries:
            path = Path(entry.path)
            try:
                metadata = path.lstat()
            except OSError as error:
                raise CacheFingerprintError("cache entry metadata is unavailable") from error
            if metadata.st_uid != uid:
                raise CacheFingerprintError("cache entry has a foreign owner")
            if directory == namespace:
                expected_directory = entry.name in ("swiftpm", "derived-data")
                expected_regular = entry.name in (CACHE_MARKER, CACHE_LOCK) or (
                    active_ready_file is not None and path == active_ready_file
                )
                if not expected_directory and not expected_regular:
                    raise CacheFingerprintError(
                        "cache namespace contains an unsupported top-level entry"
                    )
                expected_mode = 0o700 if expected_directory else 0o600
                if (
                    (expected_directory and not stat.S_ISDIR(metadata.st_mode))
                    or (expected_regular and not stat.S_ISREG(metadata.st_mode))
                    or stat.S_IMODE(metadata.st_mode) != expected_mode
                ):
                    raise CacheFingerprintError(
                        "cache namespace top-level entry metadata is unsafe"
                    )
            if stat.S_ISLNK(metadata.st_mode):
                try:
                    resolved = path.resolve(strict=True)
                except FileNotFoundError:
                    resolved = path.resolve(strict=False)
                except (OSError, RuntimeError) as error:
                    raise CacheFingerprintError("cache contains an invalid symlink") from error
                if resolved != root and root not in resolved.parents:
                    raise CacheFingerprintError("cache symlink escapes its namespace")
                continue
            mode = stat.S_IMODE(metadata.st_mode)
            if mode & 0o022:
                raise CacheFingerprintError(
                    "cache entry permissions allow group or other writes"
                )
            if stat.S_ISDIR(metadata.st_mode):
                stack.append(path)
            elif not stat.S_ISREG(metadata.st_mode):
                raise CacheFingerprintError("cache contains an unsupported entry type")


def _marker_payload(
    repository_key: str, cache_fingerprint: str, document: Mapping[str, Any]
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "repositoryKey": repository_key,
        "fingerprint": cache_fingerprint,
        "fields": document,
    }


def _record_or_verify_marker(path: Path, payload: Mapping[str, Any], uid: int) -> None:
    raw = canonical_json_bytes(payload)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
    except FileExistsError:
        descriptor = None
    except OSError as error:
        raise CacheFingerprintError("cache marker could not be created") from error
    if descriptor is not None:
        with os.fdopen(descriptor, "wb", buffering=0) as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write(raw)
            os.fsync(handle.fileno())
    try:
        metadata = path.lstat()
        observed = path.read_bytes()
    except OSError as error:
        raise CacheFingerprintError("cache marker is unavailable") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != uid
        or stat.S_IMODE(metadata.st_mode) != 0o600
    ):
        raise CacheFingerprintError("cache marker metadata is unsafe")
    if observed != raw:
        raise CacheFingerprintError("cache marker does not match its fingerprint")


def prepare_cache_namespace(
    cache_root: Path,
    repository_key: str,
    document: Mapping[str, Any],
    *,
    expected_uid: int | None = None,
) -> CachePaths:
    """Create or validate the exact reusable compiler-only namespace."""
    uid = os.geteuid() if expected_uid is None else expected_uid
    key = _require_hash(repository_key, "repository key")
    paths = cache_paths(cache_root, key, document)
    cache_fingerprint = paths.fingerprint
    root = cache_root.expanduser()
    if not root.is_absolute():
        raise CacheFingerprintError("release cache root must be absolute")
    root = Path(os.path.abspath(root))
    try:
        validate_ancestor_chain(root, expected_uid=uid)
    except CacheSecurityError as error:
        raise CacheFingerprintError(str(error)) from error
    _mkdir_private(root, uid)
    version_root = root / "v1"
    repository_root = version_root / key
    namespace = paths.namespace
    swiftpm = paths.swiftpm
    derived_data = paths.derived_data
    for path in (version_root, repository_root, namespace, swiftpm, derived_data):
        _mkdir_private(path, uid)
    try:
        validate_ancestor_chain(namespace, expected_uid=uid)
    except CacheSecurityError as error:
        raise CacheFingerprintError(str(error)) from error
    _record_or_verify_marker(
        namespace / CACHE_MARKER,
        _marker_payload(key, cache_fingerprint, document),
        uid,
    )
    _validate_cache_entries(namespace, uid)
    return paths


def cache_paths(
    cache_root: Path, repository_key: str, document: Mapping[str, Any]
) -> CachePaths:
    key = _require_hash(repository_key, "repository key")
    root = cache_root.expanduser()
    if not root.is_absolute():
        raise CacheFingerprintError("release cache root must be absolute")
    root = Path(os.path.abspath(root))
    value = fingerprint(document)
    namespace = root / "v1" / key / value
    return CachePaths(
        fingerprint=value,
        namespace=namespace,
        swiftpm=namespace / "swiftpm",
        derived_data=namespace / "derived-data",
        lock=namespace / CACHE_LOCK,
    )


def _write_ready_file(path: Path, token: str) -> None:
    if HEX_SHA256.fullmatch(token) is None:
        raise CacheFingerprintError("cache lock readiness token is invalid")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
        with os.fdopen(descriptor, "wb", buffering=0) as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write((token + "\n").encode("ascii"))
            os.fsync(handle.fileno())
    except FileExistsError as error:
        raise CacheFingerprintError(
            "cache lock readiness channel already exists"
        ) from error
    except OSError as error:
        raise CacheFingerprintError("cache lock readiness could not be recorded") from error


def hold_namespace_lock(
    namespace: Path, ready_file: Path, ready_token: str, parent_pid: int
) -> None:
    """Hold the namespace lock until the invoking builder exits or stops us."""
    uid = os.geteuid()
    namespace = namespace.resolve(strict=True)
    _metadata(namespace, uid, private_directory=True)
    if (
        ready_file.parent != namespace
        or re.fullmatch(r"\.lock-ready\.[0-9a-f]{48}", ready_file.name) is None
    ):
        raise CacheFingerprintError("cache lock readiness path is outside namespace")
    lock_path = namespace / CACHE_LOCK
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(lock_path, flags, 0o600)
    except OSError as error:
        raise CacheFingerprintError("cache lock could not be opened") from error
    stop_requested = False

    def request_stop(_signal: int, _frame: Any) -> None:
        nonlocal stop_requested
        stop_requested = True

    previous_term = signal.signal(signal.SIGTERM, request_stop)
    previous_int = signal.signal(signal.SIGINT, request_stop)
    try:
        with os.fdopen(descriptor, "r+b", buffering=0) as handle:
            metadata = os.fstat(handle.fileno())
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != uid
                or stat.S_IMODE(metadata.st_mode) != 0o600
            ):
                raise CacheFingerprintError("cache lock metadata is unsafe")
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            try:
                _validate_cache_entries(namespace, uid)
                _write_ready_file(ready_file, ready_token)
                _validate_cache_entries(
                    namespace, uid, active_ready_file=ready_file
                )
                while not stop_requested and os.getppid() == parent_pid:
                    time.sleep(0.1)
            finally:
                # Remove readiness while the lock is still held. A queued helper
                # must never validate or signal readiness while the prior
                # holder's channel remains in the namespace.
                ready_file.unlink(missing_ok=True)
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        signal.signal(signal.SIGINT, previous_int)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    commands = value.add_subparsers(dest="operation", required=True)
    for operation in ("derive", "prepare"):
        prepare = commands.add_parser(operation)
        prepare.add_argument("--project-root", type=Path, required=True)
        prepare.add_argument("--repository", required=True)
        prepare.add_argument("--repository-key", required=True)
        prepare.add_argument("--deployment-target", required=True)
        prepare.add_argument("--cache-root", type=Path, required=True)
    lock = commands.add_parser("hold-lock")
    lock.add_argument("--namespace", type=Path, required=True)
    lock.add_argument("--ready-file", type=Path, required=True)
    lock.add_argument("--ready-token", required=True)
    lock.add_argument("--parent-pid", type=int, required=True)
    return value


def main() -> int:
    args = parser().parse_args()
    try:
        if args.operation in ("derive", "prepare"):
            document = collect_fingerprint_document(
                project_root=args.project_root,
                repository=args.repository,
                repository_key=args.repository_key,
                deployment_target=args.deployment_target,
            )
            paths = (
                prepare_cache_namespace(args.cache_root, args.repository_key, document)
                if args.operation == "prepare"
                else cache_paths(args.cache_root, args.repository_key, document)
            )
            print(f"CACHE_FINGERPRINT={paths.fingerprint}")
            print(f"CACHE_NAMESPACE={paths.namespace}")
            print(f"CACHE_SWIFTPM={paths.swiftpm}")
            print(f"CACHE_DERIVED_DATA={paths.derived_data}")
        else:
            if args.parent_pid <= 1:
                raise CacheFingerprintError("cache lock parent PID is invalid")
            hold_namespace_lock(
                args.namespace, args.ready_file, args.ready_token, args.parent_pid
            )
    except CacheFingerprintError as error:
        print(f"release cache: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
