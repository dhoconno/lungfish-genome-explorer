#!/usr/bin/env python3
"""Ownership and provenance boundary for cached release executables."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile


TOOL_NAMES = ("generate_appcast", "sign_update", "generate_keys")
PROVENANCE_FILENAME = ".lungfish-sparkle-tools-provenance.json"


class CacheSecurityError(ValueError):
    """A cache path cannot be trusted for release executable discovery."""


def validate_metadata(
    metadata: os.stat_result,
    *,
    expected_uid: int,
    require_private: bool = False,
    require_directory: bool = False,
    require_regular: bool = False,
) -> None:
    if metadata.st_uid != expected_uid:
        raise CacheSecurityError("cache owner UID does not match the release user")
    if require_directory and not stat.S_ISDIR(metadata.st_mode):
        raise CacheSecurityError("cache path is not a directory")
    if require_regular and not stat.S_ISREG(metadata.st_mode):
        raise CacheSecurityError("cache path is not a regular file")
    mode = stat.S_IMODE(metadata.st_mode)
    if mode & 0o022:
        raise CacheSecurityError("cache permissions allow group or other writes")
    if require_private and mode & 0o077:
        raise CacheSecurityError("private cache permissions must be mode 0700")


def _lstat(path: Path) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise CacheSecurityError("required cache path is unavailable") from error
    if stat.S_ISLNK(metadata.st_mode):
        raise CacheSecurityError("cache path contains a symlink component")
    return metadata


def _validate_user_root(user_root: Path, expected_uid: int) -> None:
    validate_metadata(
        _lstat(user_root),
        expected_uid=expected_uid,
        require_private=True,
        require_directory=True,
    )


def _validate_descendant(
    user_root: Path,
    target: Path,
    *,
    expected_uid: int,
    final_regular: bool = False,
) -> os.stat_result:
    user_root = user_root.absolute()
    target = target.absolute()
    try:
        relative = target.relative_to(user_root)
    except ValueError as error:
        raise CacheSecurityError("cache path escapes the private user root") from error

    _validate_user_root(user_root, expected_uid)
    current = user_root
    parts = relative.parts
    for index, part in enumerate(parts):
        current = current / part
        metadata = _lstat(current)
        is_final = index == len(parts) - 1
        validate_metadata(
            metadata,
            expected_uid=expected_uid,
            require_directory=not is_final,
            require_regular=is_final and final_regular,
        )
    return _lstat(target)


def prepare_user_cache(base: Path, *, expected_uid: int | None = None) -> Path:
    uid = os.geteuid() if expected_uid is None else expected_uid
    base = base.expanduser()
    if not base.is_absolute():
        raise CacheSecurityError("scratch root must be absolute")
    if base.is_symlink():
        raise CacheSecurityError("scratch root must not be a symlink")
    try:
        base.mkdir(parents=True, mode=0o700, exist_ok=True)
    except OSError as error:
        raise CacheSecurityError("scratch root cannot be created") from error
    if base.is_symlink() or not base.is_dir():
        raise CacheSecurityError("scratch root must be a real directory")
    base = base.resolve(strict=True)
    validate_metadata(
        _lstat(base),
        expected_uid=uid,
        require_private=True,
        require_directory=True,
    )

    user_root = base / f"uid-{uid}"
    try:
        user_root.mkdir(mode=0o700)
    except FileExistsError:
        pass
    except OSError as error:
        raise CacheSecurityError("private user cache cannot be created") from error
    _validate_user_root(user_root, uid)
    return user_root


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _receipt_path(resolution_root: Path) -> Path:
    return resolution_root / PROVENANCE_FILENAME


def verify_tools(
    user_root: Path,
    resolution_root: Path,
    tools_directory: Path,
    lock_hash: str,
    *,
    expected_uid: int | None = None,
) -> None:
    uid = os.geteuid() if expected_uid is None else expected_uid
    if not (
        len(lock_hash) == 64
        and all(character in "0123456789abcdef" for character in lock_hash)
    ):
        raise CacheSecurityError("Package.resolved hash is invalid")
    _validate_descendant(user_root, resolution_root, expected_uid=uid)
    observed_hashes: dict[str, str] = {}
    for name in TOOL_NAMES:
        tool = tools_directory / name
        metadata = _validate_descendant(
            user_root, tool, expected_uid=uid, final_regular=True
        )
        if not metadata.st_mode & stat.S_IXUSR:
            raise CacheSecurityError("cached Sparkle tool is not executable")
        observed_hashes[name] = _sha256(tool)

    receipt_path = _receipt_path(resolution_root)
    receipt_metadata = _validate_descendant(
        user_root, receipt_path, expected_uid=uid, final_regular=True
    )
    if stat.S_IMODE(receipt_metadata.st_mode) != 0o600:
        raise CacheSecurityError("provenance receipt permissions must be mode 0600")
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CacheSecurityError("provenance receipt is unreadable") from error
    expected = receipt.get("tools") if isinstance(receipt, dict) else None
    if (
        not isinstance(receipt, dict)
        or receipt.get("schemaVersion") != 1
        or receipt.get("lockHash") != lock_hash
        or not isinstance(expected, dict)
        or set(expected) != set(TOOL_NAMES)
    ):
        raise CacheSecurityError("provenance receipt does not match Package.resolved")

    for name in TOOL_NAMES:
        if expected[name] != observed_hashes[name]:
            raise CacheSecurityError(
                "cached Sparkle tool fails provenance verification"
            )


def record_tools(
    user_root: Path,
    resolution_root: Path,
    tools_directory: Path,
    lock_hash: str,
    *,
    expected_uid: int | None = None,
) -> None:
    uid = os.geteuid() if expected_uid is None else expected_uid
    _validate_descendant(user_root, resolution_root, expected_uid=uid)
    hashes: dict[str, str] = {}
    for name in TOOL_NAMES:
        tool = tools_directory / name
        metadata = _validate_descendant(
            user_root, tool, expected_uid=uid, final_regular=True
        )
        if not metadata.st_mode & stat.S_IXUSR:
            raise CacheSecurityError("resolved Sparkle tool is not executable")
        hashes[name] = _sha256(tool)

    receipt_path = _receipt_path(resolution_root)
    if receipt_path.is_symlink():
        raise CacheSecurityError("provenance receipt must not be a symlink")
    payload = {"schemaVersion": 1, "lockHash": lock_hash, "tools": hashes}
    temporary: Path | None = None
    try:
        descriptor, raw_path = tempfile.mkstemp(
            prefix=".sparkle-provenance-", dir=resolution_root
        )
        temporary = Path(raw_path)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            json.dump(payload, handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        if receipt_path.is_symlink():
            raise CacheSecurityError("provenance receipt must not be a symlink")
        os.replace(temporary, receipt_path)
        temporary = None
    except OSError as error:
        raise CacheSecurityError("provenance receipt could not be recorded") from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    verify_tools(
        user_root, resolution_root, tools_directory, lock_hash, expected_uid=uid
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("base", type=Path)
    for operation in ("verify", "record"):
        command = subparsers.add_parser(operation)
        command.add_argument("user_root", type=Path)
        command.add_argument("resolution_root", type=Path)
        command.add_argument("tools_directory", type=Path)
        command.add_argument("lock_hash")
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.operation == "prepare":
            print(prepare_user_cache(args.base))
        elif args.operation == "verify":
            verify_tools(
                args.user_root,
                args.resolution_root,
                args.tools_directory,
                args.lock_hash,
            )
        else:
            record_tools(
                args.user_root,
                args.resolution_root,
                args.tools_directory,
                args.lock_hash,
            )
    except CacheSecurityError as error:
        print(f"Sparkle cache safety: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
