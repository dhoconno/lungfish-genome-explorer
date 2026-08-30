#!/usr/bin/env python3
"""Scan an assembled app for non-portable build-machine path strings."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import sys
from urllib.parse import quote_from_bytes

from release_cache_security import CacheSecurityError, validate_ancestor_chain


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SCRATCH_ROOT = Path("/private/var/tmp/lungfish-release-swiftpm")
CHUNK_SIZE = 1024 * 1024
MAX_EVIDENCE = 20
CLI_RELATIVE_PATH = Path("Contents/MacOS/lungfish-cli")
SWIFTPM_RESOURCE_SUFFIX = Path(
    "arm64-apple-macosx/release/" "LungfishGenomeBrowser_LungfishWorkflow.bundle"
)
FORBIDDEN_PATTERNS = (
    (b"/Users/", "user-home"),
    (b"/private/tmp/", "private-tmp"),
    (b"/private/var/tmp", "private-var-tmp"),
    (b"/var/folders/", "macos-temporary"),
    (b"/tmp/lungfish", "random-lungfish-tmp"),
    (b"DerivedData", "derived-data"),
    (b".worktrees/", "worktree"),
    (b"/.tmp/", "temporary-directory"),
    (b".build/xcode-cli-release", "legacy-swiftpm-scratch"),
    (b"/opt/homebrew", "homebrew"),
    (b"/usr/local/Cellar", "homebrew-cellar"),
    (b"/usr/local/Homebrew", "homebrew"),
    (os.fsencode(ROOT.resolve()), "repository-root"),
)
PATH_CONTINUATION = frozenset(
    b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~/-"
)


class ScanError(ValueError):
    """The requested scan could not be completed safely."""


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--allowed-swiftpm-fallback", required=True, type=Path)
    return parser


def _regular_files(app: Path):
    def traversal_error(error: OSError) -> None:
        raise ScanError("app payload traversal failed") from error

    for directory, directory_names, file_names in os.walk(
        app, followlinks=False, onerror=traversal_error
    ):
        directory_names.sort()
        file_names.sort()
        directory_path = Path(directory)
        for name in file_names:
            path = directory_path / name
            try:
                metadata = path.lstat()
            except OSError as error:
                raise ScanError("app payload changed or became unreadable") from error
            if stat.S_ISLNK(metadata.st_mode):
                continue
            if not stat.S_ISREG(metadata.st_mode):
                raise ScanError("app payload contains an unsupported file type")
            yield path


def _is_same_or_descendant(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def _trusted_scratch_path(path: Path) -> Path:
    if not path.is_absolute():
        raise ScanError("allowed SwiftPM fallback scratch path must be absolute")
    normalized = Path(os.path.abspath(path))
    configured_root = Path(
        os.environ.get("LUNGFISH_RELEASE_SCRATCH_ROOT", str(DEFAULT_SCRATCH_ROOT))
    ).expanduser()
    if not configured_root.is_absolute():
        raise ScanError("configured release scratch root is not trusted")
    configured_root = Path(os.path.abspath(configured_root))

    try:
        validate_ancestor_chain(configured_root, expected_uid=os.geteuid())
        validate_ancestor_chain(normalized, expected_uid=os.geteuid())
    except CacheSecurityError as error:
        raise ScanError(
            "allowed SwiftPM fallback scratch path is not trusted"
        ) from error

    home = Path(os.environ.get("HOME", str(Path.home()))).resolve(strict=False)
    repository = ROOT.resolve()
    forbidden_roots = (
        home,
        repository,
        Path("/opt/homebrew"),
        Path("/usr/local/Homebrew"),
        Path("/usr/local/Cellar"),
    )
    forbidden_scratch_patterns = tuple(
        pattern
        for pattern, _ in FORBIDDEN_PATTERNS
        if pattern
        not in (b"/private/var/tmp", b"/tmp/lungfish", os.fsencode(repository))
    )
    encoded = os.fsencode(normalized)
    if (
        not _is_same_or_descendant(normalized, configured_root)
        or any(_is_same_or_descendant(normalized, root) for root in forbidden_roots)
        or any(pattern in encoded for pattern in forbidden_scratch_patterns)
        or (
            b"/tmp/lungfish" in encoded
            and not _is_same_or_descendant(normalized, DEFAULT_SCRATCH_ROOT)
        )
    ):
        raise ScanError("allowed SwiftPM fallback scratch path is not trusted")
    return normalized


def _is_exact_fallback(data: bytes, start: int, fallback: bytes) -> bool:
    end = start + len(fallback)
    if data[start:end] != fallback:
        return False
    if end == len(data):
        return True
    return data[end] not in PATH_CONTINUATION


def _scan_file(
    path: Path,
    relative: str,
    allowed_fallback: bytes,
    fallback_count: int,
    evidence: list[tuple[str, int, str]],
) -> tuple[int, int]:
    maximum_pattern = max(
        max(len(pattern) for pattern, _ in FORBIDDEN_PATTERNS),
        len(allowed_fallback) + 1,
    )
    # Keep enough context to recognize a shorter forbidden substring that sits
    # near the end of the longer, explicitly allowed SwiftPM fallback.
    overlap = maximum_pattern * 2
    carry = b""
    total_read = 0
    next_scan_offset = 0
    findings = 0

    try:
        before = path.lstat()
        flags = os.O_RDONLY
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb", buffering=0) as handle:
            opened = os.fstat(handle.fileno())
            if (before.st_dev, before.st_ino, before.st_mode) != (
                opened.st_dev,
                opened.st_ino,
                opened.st_mode,
            ):
                raise ScanError("app payload changed while it was scanned")
            while True:
                chunk = handle.read(CHUNK_SIZE)
                final = not chunk
                data = carry + chunk
                data_start = total_read - len(carry)
                total_read += len(chunk)
                safe_end = (
                    total_read if final else max(data_start, total_read - overlap)
                )

                for pattern, label in FORBIDDEN_PATTERNS:
                    search_at = max(0, next_scan_offset - data_start)
                    while True:
                        index = data.find(pattern, search_at)
                        if index < 0:
                            break
                        absolute_offset = data_start + index
                        if absolute_offset >= safe_end:
                            break
                        finding_label = label
                        if pattern == b"/private/var/tmp":
                            exact = (
                                relative == CLI_RELATIVE_PATH.as_posix()
                                and _is_exact_fallback(data, index, allowed_fallback)
                            )
                            if exact and fallback_count == 0:
                                fallback_count += 1
                                search_at = index + 1
                                continue
                            if exact:
                                finding_label = "swiftpm-fallback"
                        elif relative == CLI_RELATIVE_PATH.as_posix():
                            fallback_start = data.find(
                                allowed_fallback,
                                max(0, index - len(allowed_fallback)),
                                min(len(data), index + len(allowed_fallback)),
                            )
                            if (
                                fallback_start >= 0
                                and fallback_start <= index
                                and index + len(pattern)
                                <= fallback_start + len(allowed_fallback)
                                and _is_exact_fallback(
                                    data, fallback_start, allowed_fallback
                                )
                            ):
                                search_at = index + 1
                                continue
                        findings += 1
                        if len(evidence) < MAX_EVIDENCE:
                            evidence.append((relative, absolute_offset, finding_label))
                        search_at = index + 1

                if final:
                    break
                next_scan_offset = safe_end
                carry = data[-overlap:] if overlap else b""
            after = os.fstat(handle.fileno())
    except OSError as error:
        raise ScanError("app payload changed or became unreadable") from error
    if (
        before.st_dev,
        before.st_ino,
        before.st_mode,
        before.st_size,
        before.st_mtime_ns,
    ) != (
        after.st_dev,
        after.st_ino,
        after.st_mode,
        after.st_size,
        after.st_mtime_ns,
    ):
        raise ScanError("app payload changed while it was scanned")

    return findings, fallback_count


def scan(app: Path, scratch_path: Path) -> tuple[int, list[tuple[str, int, str]]]:
    if not app.is_dir():
        raise ScanError("app must be a directory")
    try:
        if stat.S_ISLNK(app.lstat().st_mode):
            raise ScanError("app must not be a symlink")
    except OSError as error:
        raise ScanError("app must be a directory") from error

    normalized_scratch = _trusted_scratch_path(scratch_path)
    fallback = os.fsencode(normalized_scratch / SWIFTPM_RESOURCE_SUFFIX)
    if len(fallback) > 4096:
        raise ScanError("allowed SwiftPM fallback path is too long")
    findings = 0
    fallback_count = 0
    evidence: list[tuple[str, int, str]] = []
    for path in _regular_files(app):
        raw_relative = path.relative_to(app).as_posix()
        relative = quote_from_bytes(os.fsencode(raw_relative), safe="/._-")
        file_findings, fallback_count = _scan_file(
            path, relative, fallback, fallback_count, evidence
        )
        findings += file_findings
    return findings, evidence


def main() -> int:
    args = _parser().parse_args()
    try:
        findings, evidence = scan(args.app, args.allowed_swiftpm_fallback)
    except ScanError as error:
        print(f"portability scan error: {error}", file=sys.stderr)
        return 2

    if findings:
        for relative, offset, label in evidence:
            print(f"{relative}:{offset}:{label}")
        print(f"FAIL portability findings={findings} shown={len(evidence)}")
        return 1
    print("PASS portability")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
