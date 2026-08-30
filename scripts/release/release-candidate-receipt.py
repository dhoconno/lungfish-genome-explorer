#!/usr/bin/env python3
"""Create or verify provenance for an exact unsigned Lungfish app candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from typing import Any
from urllib.parse import urlparse

from release_cache_security import (
    CacheSecurityError,
    validate_ancestor_chain,
    validate_metadata,
)
from release_cache_fingerprint import (
    collect_fingerprint_document,
    fingerprint as cache_fingerprint,
)
from release_contract import CONTRACT_PATH, load_contract
from release_repository import RepositoryIdentityError, resolve_repository_identity


ROOT = Path(__file__).resolve().parents[2]
PACKAGE_LOCK_PATH = ROOT / "Package.resolved"
MANAGED_MANIFEST_PATH = (
    ROOT
    / "Sources"
    / "LungfishWorkflow"
    / "Resources"
    / "ManagedTools"
    / "third-party-tools-lock.json"
)
BUILDER_PATH = ROOT / "scripts" / "release" / "build-notarized-dmg.sh"
CLI_RELATIVE_PATH = Path("Contents/MacOS/lungfish-cli")
MICROMAMBA_RELATIVE_PATHS = (
    Path(
        "Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Tools/micromamba"
    ),
    Path(
        "Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/"
        "Contents/Resources/Tools/micromamba"
    ),
)
SWIFTPM_RESOURCE_SUFFIX = Path(
    "arm64-apple-macosx/release/" "LungfishGenomeBrowser_LungfishWorkflow.bundle"
)
COMMAND_TIMEOUT_SECONDS = 30
MAX_RECEIPT_BYTES = 1024 * 1024
MAX_PLIST_BYTES = 4 * 1024 * 1024
RECEIPT_FIELDS = frozenset(
    {
        "schemaVersion",
        "source",
        "release",
        "wrapper",
        "bundle",
        "inputs",
        "toolchain",
        "build",
        "artifacts",
        "cache",
    }
)


class ReceiptError(ValueError):
    """Candidate provenance could not be established without ambiguity."""


def _canonical_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        + "\n"
    ).encode("utf-8")


def _run(command: list[str], *, cwd: Path = ROOT) -> str:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReceiptError("required identity command could not be executed") from error
    if result.returncode != 0:
        raise ReceiptError("required identity command failed")
    return result.stdout.strip()


def _source_identity() -> dict[str, Any]:
    status = _run(["git", "status", "--porcelain", "--untracked-files=all"])
    if status:
        raise ReceiptError("source tree is not clean")
    commit = _run(["git", "rev-parse", "--verify", "HEAD"])
    if re.fullmatch(r"[0-9a-fA-F]{40}", commit) is None:
        raise ReceiptError("repository has no valid HEAD commit")
    return {"clean": True, "commit": commit.lower()}


def _normalize_existing_directory(path: Path, label: str) -> Path:
    if not path.is_absolute():
        raise ReceiptError(f"{label} must be absolute")
    normalized = Path(os.path.abspath(path))
    try:
        validate_ancestor_chain(normalized, expected_uid=os.geteuid())
        metadata = normalized.lstat()
        validate_metadata(
            metadata,
            expected_uid=os.geteuid(),
            require_directory=True,
        )
    except (OSError, CacheSecurityError) as error:
        raise ReceiptError(f"{label} is not a trusted directory") from error
    return normalized


def _normalize_app(path: Path) -> Path:
    app = _normalize_existing_directory(path, "app path")
    try:
        if stat.S_ISLNK(app.lstat().st_mode):
            raise ReceiptError("app path must not be a symlink")
    except OSError as error:
        raise ReceiptError("app path is unavailable") from error
    return app


def _safe_output_path(path: Path) -> Path:
    if not path.is_absolute():
        raise ReceiptError("receipt output path must be absolute")
    output = Path(os.path.abspath(path))
    _normalize_existing_directory(output.parent, "receipt output directory")
    if output.is_symlink():
        raise ReceiptError("receipt output must not be a symlink")
    if output.exists():
        try:
            metadata = output.lstat()
        except OSError as error:
            raise ReceiptError("receipt output is unavailable") from error
        if not stat.S_ISREG(metadata.st_mode):
            raise ReceiptError("receipt output must be a regular file")
    return output


def _file_metadata_matches(left: os.stat_result, right: os.stat_result) -> bool:
    return (
        left.st_dev,
        left.st_ino,
        left.st_mode,
        left.st_size,
        left.st_mtime_ns,
    ) == (
        right.st_dev,
        right.st_ino,
        right.st_mode,
        right.st_size,
        right.st_mtime_ns,
    )


def _hash_regular(path: Path) -> tuple[str, bool, int]:
    try:
        before = path.lstat()
    except OSError as error:
        raise ReceiptError("required candidate file is unavailable") from error
    if not stat.S_ISREG(before.st_mode):
        raise ReceiptError("required candidate path is not a regular file")
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    digest = hashlib.sha256()
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb", buffering=0) as handle:
            opened = os.fstat(handle.fileno())
            if not _file_metadata_matches(before, opened):
                raise ReceiptError("candidate changed while it was inspected")
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
            after = os.fstat(handle.fileno())
    except OSError as error:
        raise ReceiptError("required candidate file is unreadable") from error
    if not _file_metadata_matches(before, after):
        raise ReceiptError("candidate changed while it was inspected")
    return digest.hexdigest(), bool(before.st_mode & 0o111), before.st_size


def _read_bounded_regular(path: Path, maximum_bytes: int, label: str) -> bytes:
    try:
        before = path.lstat()
    except OSError as error:
        raise ReceiptError(f"{label} is unavailable") from error
    if not stat.S_ISREG(before.st_mode) or before.st_size > maximum_bytes:
        raise ReceiptError(f"{label} is not a bounded regular file")
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb", buffering=0) as handle:
            opened = os.fstat(handle.fileno())
            if not _file_metadata_matches(before, opened):
                raise ReceiptError(f"{label} changed while it was inspected")
            chunks = []
            remaining = maximum_bytes + 1
            while remaining:
                chunk = handle.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            contents = b"".join(chunks)
            after = os.fstat(handle.fileno())
    except OSError as error:
        raise ReceiptError(f"{label} is unreadable") from error
    if len(contents) > maximum_bytes or not _file_metadata_matches(before, after):
        raise ReceiptError(f"{label} changed while it was inspected")
    return contents


def _artifact_file(app: Path, relative: Path) -> dict[str, Any]:
    digest, executable, _ = _hash_regular(app / relative)
    if not executable:
        raise ReceiptError("required candidate executable is not executable")
    return {
        "executable": True,
        "path": relative.as_posix(),
        "sha256": digest,
    }


def _micromamba_relative_path(app: Path) -> Path:
    present = []
    for relative in MICROMAMBA_RELATIVE_PATHS:
        try:
            (app / relative).lstat()
        except FileNotFoundError:
            continue
        except OSError as error:
            raise ReceiptError("micromamba candidate path is unavailable") from error
        present.append(relative)
    if len(present) != 1:
        raise ReceiptError("candidate must contain exactly one micromamba executable")
    return present[0]


def _hash_record(digest: Any, *parts: bytes) -> None:
    for part in parts:
        digest.update(len(part).to_bytes(8, "big"))
        digest.update(part)


def _payload_digest(app: Path) -> str:
    app_root = app.resolve(strict=True)
    digest = hashlib.sha256()

    def visit(directory: Path) -> None:
        try:
            entries = sorted(
                os.scandir(directory), key=lambda entry: os.fsencode(entry.name)
            )
        except OSError as error:
            raise ReceiptError("app payload changed or became unreadable") from error
        for entry in entries:
            path = Path(entry.path)
            relative = path.relative_to(app).as_posix()
            relative_bytes = os.fsencode(relative)
            try:
                metadata = path.lstat()
            except OSError as error:
                raise ReceiptError(
                    "app payload changed or became unreadable"
                ) from error
            if stat.S_ISLNK(metadata.st_mode):
                try:
                    raw_target = os.readlink(path)
                    resolved_target = path.resolve(strict=True)
                except OSError as error:
                    raise ReceiptError(
                        "app payload contains an invalid symlink"
                    ) from error
                if (
                    resolved_target != app_root
                    and app_root not in resolved_target.parents
                ):
                    raise ReceiptError("app payload symlink escapes app")
                _hash_record(digest, b"L", relative_bytes, os.fsencode(raw_target))
            elif stat.S_ISDIR(metadata.st_mode):
                _hash_record(digest, b"D", relative_bytes)
                visit(path)
            elif stat.S_ISREG(metadata.st_mode):
                file_hash, executable, size = _hash_regular(path)
                _hash_record(
                    digest,
                    b"F",
                    relative_bytes,
                    b"1" if executable else b"0",
                    str(size).encode("ascii"),
                    file_hash.encode("ascii"),
                )
            else:
                raise ReceiptError("app payload contains an unsupported file type")

    visit(app)
    try:
        final_root = app.resolve(strict=True)
    except OSError as error:
        raise ReceiptError("app payload changed while it was inspected") from error
    if final_root != app_root:
        raise ReceiptError("app payload changed while it was inspected")
    return digest.hexdigest()


def _read_plist(app: Path) -> dict[str, Any]:
    path = app / "Contents" / "Info.plist"
    try:
        value = plistlib.loads(
            _read_bounded_regular(path, MAX_PLIST_BYTES, "Info.plist")
        )
    except plistlib.InvalidFileException as error:
        raise ReceiptError("Info.plist is unreadable") from error
    if not isinstance(value, dict):
        raise ReceiptError("Info.plist root must be a dictionary")
    return value


def _required_plist_string(info: dict[str, Any], key: str) -> str:
    value = info.get(key)
    if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
        raise ReceiptError(f"Info.plist {key} must be a non-empty one-line string")
    return value


def _bundle_identity(
    app: Path, channel_name: str
) -> tuple[dict[str, Any], dict[str, Any]]:
    contract = load_contract(CONTRACT_PATH)
    channel = contract.channel(channel_name)
    info = _read_plist(app)
    values = {
        "displayName": _required_plist_string(info, "CFBundleDisplayName"),
        "name": _required_plist_string(info, "CFBundleName"),
        "identifier": _required_plist_string(info, "CFBundleIdentifier"),
        "releaseChannel": _required_plist_string(info, "LungfishReleaseChannel"),
        "feedURL": _required_plist_string(info, "SUFeedURL"),
    }
    expected = {
        "displayName": channel.displayName,
        "name": channel.bundleName,
        "identifier": channel.bundleIdentifier,
        "releaseChannel": channel.releaseChannel,
    }
    if any(values[key] != expected[key] for key in expected):
        raise ReceiptError("app bundle metadata does not match the release contract")
    parsed_feed = urlparse(values["feedURL"])
    expected_feed_suffix = f"/{channel.sparkleRelease}/{channel.appcastFilename}"
    if (
        parsed_feed.scheme != "https"
        or not parsed_feed.netloc
        or not parsed_feed.path.endswith(expected_feed_suffix)
    ):
        raise ReceiptError("app feed metadata does not match the release contract")
    if app.name != channel.appBundleFilename:
        raise ReceiptError("app wrapper filename does not match the release contract")
    executable = _required_plist_string(info, "CFBundleExecutable")
    if "/" in executable or executable in (".", ".."):
        raise ReceiptError("Info.plist CFBundleExecutable is unsafe")
    wrapper = {"executable": executable, "filename": app.name}
    release = {
        "build": _required_plist_string(info, "CFBundleVersion"),
        "channel": channel_name,
        "version": _required_plist_string(info, "CFBundleShortVersionString"),
    }
    return {"bundle": values, "release": release, "wrapper": wrapper}, info


def _parse_xcode_identity(raw: str) -> tuple[str, str]:
    version = re.search(r"^Xcode\s+(\S+)\s*$", raw, re.MULTILINE)
    build = re.search(r"^Build version\s+(\S+)\s*$", raw, re.MULTILINE)
    if version is None or build is None:
        raise ReceiptError("could not parse Xcode identity")
    return version.group(1), build.group(1)


def _parse_version(raw: str, label: str) -> str:
    match = re.search(r"\d+(?:\.\d+)+", raw)
    if match is None:
        raise ReceiptError(f"could not parse {label} identity")
    return match.group(0)


def _toolchain_identity() -> dict[str, Any]:
    xcode_version, xcode_build = _parse_xcode_identity(_run(["xcodebuild", "-version"]))
    contract = load_contract(CONTRACT_PATH)
    swift_identity = _run(["xcrun", "swift", "--version"])
    return {
        "architecture": _run(["uname", "-m"]),
        "deploymentTarget": contract.toolchain.deploymentTarget,
        "sdkVersion": _parse_version(
            _run(["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
            "macOS SDK",
        ),
        "sdkBuildVersion": _run(
            ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]
        ),
        "swiftCompilerIdentity": swift_identity,
        "swiftVersion": _parse_version(swift_identity, "Swift"),
        "xcodeBuildVersion": xcode_build,
        "xcodeVersion": xcode_version,
    }


def _input_hash(path: Path) -> str:
    return _hash_regular(path)[0]


def _micromamba_upstream_hash(architecture: str) -> str:
    try:
        manifest = json.loads(MANAGED_MANIFEST_PATH.read_text(encoding="utf-8"))
        hashes = manifest["bootstrap"]["micromamba"]["sha256"]
        value = hashes[f"osx-{architecture}"]
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise ReceiptError(
            "managed manifest lacks the micromamba upstream hash"
        ) from error
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ReceiptError("managed manifest micromamba upstream hash is invalid")
    return value


def _build_receipt(
    app_path: Path,
    channel: str,
    scratch_path: Path,
    remote: str,
    github_repository: str | None,
) -> dict[str, Any]:
    source = _source_identity()
    app = _normalize_app(app_path)
    scratch = _normalize_existing_directory(scratch_path, "scratch path")
    identities, _ = _bundle_identity(app, channel)
    toolchain = _toolchain_identity()
    try:
        repository = resolve_repository_identity(ROOT, remote, github_repository)
    except RepositoryIdentityError as error:
        raise ReceiptError("canonical repository identity is unavailable") from error
    cache_fields = collect_fingerprint_document(
        project_root=ROOT,
        repository=f"github.com/{repository.github_repository}",
        repository_key=repository.repository_key,
        deployment_target=toolchain["deploymentTarget"],
    )
    executable = Path("Contents/MacOS") / identities["wrapper"]["executable"]
    inputs = {
        "builderSha256": _input_hash(BUILDER_PATH),
        "managedManifestSha256": _input_hash(MANAGED_MANIFEST_PATH),
        "micromambaUpstreamSha256": _micromamba_upstream_hash(
            toolchain["architecture"]
        ),
        "packageResolvedSha256": _input_hash(PACKAGE_LOCK_PATH),
        "releaseContractSha256": _input_hash(CONTRACT_PATH),
    }
    artifacts = {
        "archiveExecutable": _artifact_file(app, executable),
        "lungfishCLI": _artifact_file(app, CLI_RELATIVE_PATH),
        "micromamba": _artifact_file(app, _micromamba_relative_path(app)),
        "packagedAppPayloadSha256": _payload_digest(app),
    }
    receipt = {
        "schemaVersion": 1,
        "source": source,
        **identities,
        "inputs": inputs,
        "toolchain": toolchain,
        "build": {
            "scratchPath": str(scratch),
            "swiftPMResourceFallback": str(scratch / SWIFTPM_RESOURCE_SUFFIX),
        },
        "artifacts": artifacts,
        "cache": {
            "schemaVersion": 1,
            "fingerprint": cache_fingerprint(cache_fields),
            "fields": cache_fields,
        },
    }
    if _source_identity() != source:
        raise ReceiptError("source identity changed while creating receipt")
    return receipt


def _write_receipt(path: Path, payload: dict[str, Any], app_path: Path) -> None:
    output = _safe_output_path(path)
    app = _normalize_app(app_path)
    current = output.parent
    while True:
        try:
            if os.path.samefile(current, app):
                raise ReceiptError("receipt output must be outside the app")
        except FileNotFoundError:
            pass
        except OSError as error:
            raise ReceiptError(
                "receipt output containment could not be verified"
            ) from error
        if current == current.parent:
            break
        current = current.parent
    temporary: Path | None = None
    try:
        descriptor, raw_path = tempfile.mkstemp(
            prefix=f".{output.name}.tmp-", dir=output.parent
        )
        temporary = Path(raw_path)
        with os.fdopen(descriptor, "wb", buffering=0) as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write(_canonical_bytes(payload))
            os.fsync(handle.fileno())
        if output.is_symlink():
            raise ReceiptError("receipt output must not be a symlink")
        os.replace(temporary, output)
        temporary = None
    except OSError as error:
        raise ReceiptError("receipt could not be written safely") from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _read_receipt(path: Path) -> dict[str, Any]:
    if not path.is_absolute():
        raise ReceiptError("receipt path must be absolute")
    receipt_path = Path(os.path.abspath(path))
    _normalize_existing_directory(receipt_path.parent, "receipt directory")
    if receipt_path.is_symlink():
        raise ReceiptError("receipt must not be a symlink")
    try:
        metadata = receipt_path.lstat()
    except OSError as error:
        raise ReceiptError("receipt is unavailable") from error
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_RECEIPT_BYTES:
        raise ReceiptError("receipt is not a bounded regular file")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise ReceiptError("receipt permissions must be mode 0600")
    raw = _read_bounded_regular(receipt_path, MAX_RECEIPT_BYTES, "receipt")
    try:
        value = json.loads(raw)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ReceiptError("receipt is not valid JSON") from error
    if not isinstance(value, dict):
        raise ReceiptError("receipt root must be an object")
    if value.get("schemaVersion") != 1:
        raise ReceiptError("unsupported receipt schema")
    if set(value) != RECEIPT_FIELDS:
        raise ReceiptError("receipt fields are missing or unknown")
    if raw != _canonical_bytes(value):
        raise ReceiptError("receipt JSON is not canonical")
    cache = value.get("cache")
    if (
        not isinstance(cache, dict)
        or set(cache) != {"schemaVersion", "fingerprint", "fields"}
        or cache.get("schemaVersion") != 1
        or not isinstance(cache.get("fields"), dict)
        or cache.get("fingerprint") != cache_fingerprint(cache["fields"])
    ):
        raise ReceiptError("cache fingerprint does not match its canonical fields")
    return value


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    create = subparsers.add_parser("create")
    create.add_argument("--app", required=True, type=Path)
    create.add_argument("--output", required=True, type=Path)
    create.add_argument("--channel", required=True, choices=("preview", "stable"))
    create.add_argument("--scratch-path", required=True, type=Path)
    create.add_argument("--remote", default="origin")
    create.add_argument("--github-repository")
    verify = subparsers.add_parser("verify")
    verify.add_argument("--app", required=True, type=Path)
    verify.add_argument("--receipt", required=True, type=Path)
    verify.add_argument("--channel", required=True, choices=("preview", "stable"))
    verify.add_argument("--scratch-path", required=True, type=Path)
    verify.add_argument("--remote", default="origin")
    verify.add_argument("--github-repository")
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.operation == "create":
            payload = _build_receipt(
                args.app,
                args.channel,
                args.scratch_path,
                args.remote,
                args.github_repository,
            )
            _write_receipt(args.output, payload, args.app)
            print("PASS unsigned candidate receipt created")
        else:
            receipt = _read_receipt(args.receipt)
            observed = _build_receipt(
                args.app,
                args.channel,
                args.scratch_path,
                args.remote,
                args.github_repository,
            )
            if receipt != observed:
                raise ReceiptError("unsigned candidate receipt does not match")
            print("PASS unsigned candidate receipt")
    except (ReceiptError, ValueError) as error:
        print(f"FAIL unsigned candidate receipt: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
