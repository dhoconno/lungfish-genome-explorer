#!/usr/bin/env python3
"""Prune stale Lungfish release compiler-cache namespaces, only when asked.

The release builder keeps disposable Xcode and SwiftPM intermediates under
<cache-root>/v1/<repository key>/<fingerprint>/ and never prunes them, so
superseded namespaces pile up (about 4 GB each). This is the separate,
explicit maintenance action that removes them.

    python3 scripts/release/prune-release-cache.py [--cache-root PATH] [--keep N] [--apply]

The default is a dry run: it lists every namespace with its size and last-used
time as KEEP or REMOVE and deletes nothing. --apply removes the REMOVE ones.
--keep N (default 2, minimum 1; enough for one Preview and one Stable namespace) keeps the N most recently used namespaces per
repository key. Last used is the newest mtime of the namespace directory, its
marker and its .build.lock. The default cache root is
$LUNGFISH_RELEASE_CACHE_ROOT, else /private/var/tmp/lungfish-release-cache,
as in the other release scripts.

Safety rules:
  * Only v1/<64 lowercase hex>/<64 lowercase hex>/ directories holding a
    regular-file .lungfish-release-cache.json marker, and the app smoke copies
    described below, are considered. Anything else is listed as "ignored" and
    never touched.
  * Nothing is followed through a symlink (lstat at every level). A symlink, or
    an entry owned by another user, where the cache root, v1, a repository key,
    a namespace, its marker or its lock belongs refuses the whole run.
  * A running build holds an exclusive flock on its namespace's .build.lock.
    Before anything is removed a non-blocking exclusive lock is tried on every
    namespace, kept ones included. Any held lock refuses the whole run (a dry
    run too). Those probe locks are released before deleting. Each namespace is
    locked again right before it is removed and removed while the lock is held.
    The lock protects a build that is compiling, so do not start a release
    while --apply runs.
  * Removal is shutil.rmtree on the exact validated namespace path, never on a
    parent. Repository key directories and v1 are never removed.
  * The app smoke gate copies the candidate into <cache-root>/lungfish-app-smoke.*/
    with a .lungfish-app-smoke-copy.json marker and holds that folder's
    .build.lock while it runs. The gate removes the folder when it ends and
    takes the marker away last, so a marked folder whose lock nobody holds was
    left by a gate that was killed or whose removal failed. A folder that a kill
    caught before the gate wrote its marker is listed as "ignored" and stays
    until someone removes it by hand. A marked folder is always listed as
    REMOVE, whatever --keep says, and a held lock refuses the run as a build's
    lock does.

Exit status: 0 success (including nothing to do), 64 usage error or unsafe
layout, 75 a build lock is held, 1 a removal failed.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import fcntl
import os
from pathlib import Path
import shutil
import stat
import sys
import time
from typing import Mapping, NoReturn, Sequence

from release_cache_fingerprint import (CACHE_LOCK, CACHE_MARKER, HEX_SHA256, SMOKE_COPY_MARKER,
                                       SMOKE_COPY_PREFIX)


DEFAULT_CACHE_ROOT = Path("/private/var/tmp/lungfish-release-cache")
CACHE_ROOT_VARIABLE = "LUNGFISH_RELEASE_CACHE_ROOT"
LAYOUT_VERSION = "v1"  # the directory cache_paths() places under the cache root
PREFIX_LENGTH = 12
GIB = 1 << 30
EXIT_FAILED = 1
EXIT_USAGE = 64
EXIT_BUSY = 75


class LayoutError(Exception):
    """The cache is not a layout this command is willing to delete from."""

    def __init__(self, *problems: str) -> None:
        super().__init__("; ".join(problems))
        self.problems = list(problems)


class BusyError(Exception):
    """A release build holds the lock of the namespace about to be removed."""


@dataclass(frozen=True)
class CacheNamespace:
    repository_key: str
    fingerprint: str
    path: Path
    identity: tuple[int, int]  # (st_dev, st_ino) of the directory when scanned
    last_used_ns: int


@dataclass
class Scan:
    namespaces: list[CacheNamespace] = field(default_factory=list)
    # Copies of a candidate an app smoke gate left in the cache root. Their repository_key is "".
    smoke_copies: list[CacheNamespace] = field(default_factory=list)
    ignored: list[str] = field(default_factory=list)
    unsafe: list[str] = field(default_factory=list)


class UsageParser(argparse.ArgumentParser):
    """Exit 64 (EX_USAGE) on a usage error instead of argparse's default 2."""

    def error(self, message: str) -> NoReturn:
        self.print_usage(sys.stderr)
        self.exit(EXIT_USAGE, f"{self.prog}: error: {message}\n")


def current_uid() -> int:
    return os.geteuid()


def shown(value: object) -> str:
    """Text that is safe to print: control characters in names are escaped."""
    return "".join(
        character
        if character.isprintable()
        else character.encode("unicode_escape").decode("ascii")
        for character in str(value)
    )


def plural(count: int, noun: str) -> str:
    return f"{count} {noun}" if count == 1 else f"{count} {noun}s"


def gib(size_bytes: int) -> str:
    return f"{size_bytes / GIB:.1f}"


def last_used_text(nanoseconds: int) -> str:
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(nanoseconds // 1_000_000_000))


def lstat(path: Path) -> os.stat_result | None:
    """Status of the path itself, never of a symlink target; None if missing."""
    try:
        return path.lstat()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise LayoutError(
            f"cannot inspect {shown(path)}: {error.strerror or error}"
        ) from error


def list_names(directory: Path) -> list[str]:
    try:
        return sorted(os.listdir(directory))
    except OSError as error:
        raise LayoutError(
            f"cannot list {shown(directory)}: {error.strerror or error}"
        ) from error


def file_problem(status: os.stat_result, uid: int) -> str | None:
    if stat.S_ISLNK(status.st_mode):
        return "is a symlink"
    if not stat.S_ISREG(status.st_mode):
        return "is not a regular file"
    if status.st_uid != uid:
        return "is not owned by the current user"
    return None


def require_directory(path: Path, uid: int, label: str) -> bool:
    """True for a real directory owned by uid, False if missing, else refuse."""
    status = lstat(path)
    if status is None:
        return False
    if stat.S_ISLNK(status.st_mode):
        problem = "is a symlink"
    elif not stat.S_ISDIR(status.st_mode):
        problem = "is not a directory"
    elif status.st_uid != uid:
        problem = "is not owned by the current user"
    else:
        return True
    raise LayoutError(f"{label} {problem}")


def inspect_directory(
    path: Path, uid: int, label: str, scan: Scan
) -> os.stat_result | None:
    """Status of a real directory owned by uid, else record why it is not one."""
    status = lstat(path)
    if status is None:
        return None
    if stat.S_ISLNK(status.st_mode):
        scan.unsafe.append(f"{label} is a symlink")
    elif not stat.S_ISDIR(status.st_mode):
        scan.ignored.append(f"{label} (not a directory)")
    elif status.st_uid != uid:
        scan.unsafe.append(f"{label} is not owned by the current user")
    else:
        return status
    return None


def scan_namespace(repository: Path, name: str, uid: int, scan: Scan) -> None:
    label = f"{LAYOUT_VERSION}/{repository.name}/{shown(name)}"
    if HEX_SHA256.fullmatch(name) is None:
        scan.ignored.append(f"{label} (not a fingerprint)")
        return
    found = marked_directory(repository / name, label, CACHE_MARKER, uid, scan)
    if found is not None:
        scan.namespaces.append(found(repository.name, name))


def marked_directory(path: Path, label: str, marker_name: str, uid: int, scan: Scan):
    """For a real directory owned by uid that holds a regular-file marker and
    a safe lock, a function of (repository key, name) that makes its
    CacheNamespace. Otherwise None, after recording why in `scan`."""
    status = inspect_directory(path, uid, label, scan)
    if status is None:
        return None
    marker = lstat(path / marker_name)
    if marker is None or not (
        stat.S_ISREG(marker.st_mode) or stat.S_ISLNK(marker.st_mode)
    ):
        scan.ignored.append(f"{label} (no regular-file {marker_name})")
        return None
    lock = lstat(path / CACHE_LOCK)
    for entry_name, entry in ((marker_name, marker), (CACHE_LOCK, lock)):
        problem = None if entry is None else file_problem(entry, uid)
        if problem is not None:
            scan.unsafe.append(f"{label}/{entry_name} {problem}")
            return None
    last_used = max(
        status.st_mtime_ns,
        marker.st_mtime_ns,
        0 if lock is None else lock.st_mtime_ns,
    )
    return lambda repository_key, name: CacheNamespace(
        repository_key=repository_key,
        fingerprint=name,
        path=path,
        identity=(status.st_dev, status.st_ino),
        last_used_ns=last_used,
    )


def scan_smoke_copy(root: Path, name: str, uid: int, scan: Scan) -> None:
    """A folder an app smoke gate made for its copy of a candidate."""
    found = marked_directory(root / name, shown(name), SMOKE_COPY_MARKER, uid, scan)
    if found is not None:
        scan.smoke_copies.append(found("", name))


def scan_repository(version_root: Path, name: str, uid: int, scan: Scan) -> None:
    label = f"{LAYOUT_VERSION}/{shown(name)}"
    if HEX_SHA256.fullmatch(name) is None:
        scan.ignored.append(f"{label} (not a repository key)")
        return
    path = version_root / name
    if inspect_directory(path, uid, label, scan) is None:
        return
    for fingerprint in list_names(path):
        try:
            scan_namespace(path, fingerprint, uid, scan)
        except LayoutError as error:
            scan.unsafe.extend(error.problems)


def scan_cache(root: Path, uid: int) -> Scan:
    """Classify everything under the cache root without following any link."""
    scan = Scan()
    if not require_directory(root, uid, f"cache root {shown(root)}"):
        return scan
    for name in list_names(root):
        if name.startswith(SMOKE_COPY_PREFIX):
            try:
                scan_smoke_copy(root, name, uid, scan)
            except LayoutError as error:
                scan.unsafe.extend(error.problems)
        elif name != LAYOUT_VERSION:
            scan.ignored.append(f"{shown(name)} (outside the {LAYOUT_VERSION} layout)")
    version_root = root / LAYOUT_VERSION
    if require_directory(version_root, uid, shown(version_root)):
        for name in list_names(version_root):
            try:
                scan_repository(version_root, name, uid, scan)
            except LayoutError as error:
                scan.unsafe.extend(error.problems)
    if scan.unsafe:
        raise LayoutError(*scan.unsafe)
    return scan


def ranked(namespaces: Sequence[CacheNamespace]) -> list[CacheNamespace]:
    """By repository key, then newest first; equal times go to the lower fingerprint."""
    return sorted(
        namespaces,
        key=lambda item: (item.repository_key, -item.last_used_ns, item.fingerprint),
    )


def select_removals(namespaces: Sequence[CacheNamespace], keep: int) -> list[CacheNamespace]:
    """Everything beyond the newest `keep` namespaces of each repository key."""
    seen: dict[str, int] = {}
    removals: list[CacheNamespace] = []
    for namespace in ranked(namespaces):
        seen[namespace.repository_key] = seen.get(namespace.repository_key, 0) + 1
        if seen[namespace.repository_key] > keep:
            removals.append(namespace)
    return removals


def tree_size_bytes(path: Path) -> int:
    """Allocated bytes under path (like du). Links are counted, never followed."""
    total = 0
    pending = [str(path)]
    while pending:
        directory = pending.pop()
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    try:
                        status = entry.stat(follow_symlinks=False)
                    except FileNotFoundError:
                        continue  # removed while we looked
                    total += status.st_blocks * 512
                    if stat.S_ISDIR(status.st_mode):
                        pending.append(entry.path)
        except FileNotFoundError:
            continue
        except OSError as error:
            raise LayoutError(
                f"cannot read {shown(directory)}: {error.strerror or error}"
            ) from error
    return total


def open_lock(namespace: Path, uid: int, *, create: bool) -> int:
    """Open the build lock read-only without following links.

    A missing lock raises FileNotFoundError unless create is set.
    """
    flags = os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW
    if create:
        flags |= os.O_CREAT
    path = namespace / CACHE_LOCK
    try:
        descriptor = os.open(path, flags, 0o600)
    except FileNotFoundError:
        raise
    except OSError as error:
        raise LayoutError(
            f"cannot open {shown(path)}: {error.strerror or error}"
        ) from error
    status = os.fstat(descriptor)
    if file_problem(status, uid) is not None:
        os.close(descriptor)
        raise LayoutError(f"{shown(path)} is not a regular file owned by the current user")
    return descriptor


def try_lock(descriptor: int, namespace: Path) -> bool:
    """Take the exclusive build lock without waiting; False if a build holds it."""
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    except OSError as error:
        raise LayoutError(
            f"cannot lock {shown(namespace / CACHE_LOCK)}: {error.strerror or error}"
        ) from error
    return True


def probe_locks(namespaces: Sequence[CacheNamespace], uid: int) -> list[CacheNamespace]:
    """Namespaces whose build lock is held. Every probe lock is released on return."""
    busy: list[CacheNamespace] = []
    for namespace in namespaces:
        try:
            descriptor = open_lock(namespace.path, uid, create=False)
        except FileNotFoundError:
            continue  # never locked, so no build can be holding it
        try:
            if not try_lock(descriptor, namespace.path):
                busy.append(namespace)
        finally:
            os.close(descriptor)  # closing releases the flock
    return busy


def remove_namespace(namespace: CacheNamespace, uid: int) -> None:
    """Lock the namespace, then remove exactly its validated path under the lock."""
    status = lstat(namespace.path)
    if status is None or (status.st_dev, status.st_ino) != namespace.identity:
        raise LayoutError(f"{shown(namespace.path)} changed since it was scanned")
    descriptor = open_lock(namespace.path, uid, create=True)
    try:
        if not try_lock(descriptor, namespace.path):
            raise BusyError(shown(namespace.path))
        shutil.rmtree(namespace.path)
    finally:
        os.close(descriptor)


def row_label(namespace: CacheNamespace) -> str:
    if not namespace.repository_key:
        return f"app smoke copy  {shown(namespace.fingerprint)}"
    return (
        f"{namespace.repository_key[:PREFIX_LENGTH]}  "
        f"{namespace.fingerprint[:PREFIX_LENGTH]}"
    )


def listing_row(namespace: CacheNamespace, size_bytes: int, action: str) -> str:
    return (
        f"{row_label(namespace)}  "
        f"{gib(size_bytes):>6} GiB  {last_used_text(namespace.last_used_ns)}  {action}"
    )


def print_listing(scan: Scan, removals: Sequence[CacheNamespace]) -> dict[Path, int]:
    """One line per namespace, printed as each is measured. Returns the sizes."""
    removing = {namespace.path for namespace in removals}
    sizes: dict[Path, int] = {}
    for namespace in ranked(scan.namespaces):
        sizes[namespace.path] = tree_size_bytes(namespace.path)
        action = "REMOVE" if namespace.path in removing else "KEEP"
        print(listing_row(namespace, sizes[namespace.path], action), flush=True)
    for leftover in scan.smoke_copies:
        sizes[leftover.path] = tree_size_bytes(leftover.path)
        print(listing_row(leftover, sizes[leftover.path], "REMOVE"), flush=True)
    for entry in scan.ignored:
        print(f"ignored  {entry}")
    return sizes


def apply_removals(
    removals: Sequence[CacheNamespace], sizes: Mapping[Path, int], uid: int
) -> int:
    """Remove oldest first. Stops at the first problem and reports what it freed."""
    reclaimed = removed = exit_status = 0
    for namespace in sorted(removals, key=lambda item: item.last_used_ns):
        try:
            remove_namespace(namespace, uid)
        except BusyError as error:
            print(
                f"prune-release-cache: a release build now holds the lock of {error}; stopping",
                file=sys.stderr,
            )
            exit_status = EXIT_BUSY
        except LayoutError as error:
            print(f"prune-release-cache: {error}; stopping", file=sys.stderr)
            exit_status = EXIT_USAGE
        except OSError as error:
            print(
                f"prune-release-cache: could not remove {shown(namespace.path)}: "
                f"{error.strerror or error}. It may be partly removed; delete the "
                "leftover directory by hand before the next release build.",
                file=sys.stderr,
            )
            exit_status = EXIT_FAILED
        if exit_status:
            break
        removed += 1
        reclaimed += sizes[namespace.path]
        print(
            f"removed  {row_label(namespace)}  {gib(sizes[namespace.path])} GiB",
            flush=True,
        )
    print(f"Reclaimed {gib(reclaimed)} GiB from {plural(removed, 'namespace')}.")
    return exit_status


def refuse(reason: str, details: Sequence[str], status: int) -> int:
    print(
        f"prune-release-cache: refusing to prune because {reason}. Nothing was removed.",
        file=sys.stderr,
    )
    for detail in details:
        print(f"  {detail}", file=sys.stderr)
    return status


def prune(root: Path, keep: int, *, apply: bool, uid: int) -> int:
    try:
        scan = scan_cache(root, uid)
        busy = probe_locks([*scan.namespaces, *scan.smoke_copies], uid)
    except LayoutError as error:
        return refuse("the cache layout is unsafe", error.problems, EXIT_USAGE)
    if busy:
        return refuse(
            f"a release build holds the lock of {plural(len(busy), 'namespace')}",
            [f"busy: {shown(namespace.path)}" for namespace in busy],
            EXIT_BUSY,
        )
    if not scan.namespaces and not scan.smoke_copies:
        for entry in scan.ignored:
            print(f"ignored  {entry}")
        print(f"No release cache namespaces under {shown(root)}; nothing to do.")
        return 0
    removals = select_removals(scan.namespaces, keep)
    print(
        f"Release compiler cache {shown(root)}: "
        f"keeping the newest {keep} per repository key."
    )
    try:
        sizes = print_listing(scan, removals)
    except LayoutError as error:
        return refuse("the cache layout is unsafe", error.problems, EXIT_USAGE)
    removals = [*removals, *scan.smoke_copies]
    if not removals:
        print("Nothing to remove.")
        return 0
    if not apply:
        total = sum(sizes[namespace.path] for namespace in removals)
        print(
            f"Dry run: --apply would remove {plural(len(removals), 'namespace')} "
            f"and reclaim {gib(total)} GiB. Nothing was deleted."
        )
        return 0
    return apply_removals(removals, sizes, uid)


def keep_count(text: str) -> int:
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text!r} is not a whole number") from None
    if value < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return value


def absolute_path(text: str) -> Path:
    try:
        path = Path(text).expanduser()
    except RuntimeError as error:
        raise argparse.ArgumentTypeError(str(error)) from None
    if not path.is_absolute():
        raise argparse.ArgumentTypeError(f"{text!r} is not an absolute path")
    return Path(os.path.abspath(path))


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = UsageParser(
        prog="prune-release-cache.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        allow_abbrev=False,
    )
    parser.add_argument(
        "--cache-root",
        type=absolute_path,
        help=f"cache root (default: ${CACHE_ROOT_VARIABLE} or {DEFAULT_CACHE_ROOT})",
    )
    parser.add_argument(
        "--keep",
        type=keep_count,
        default=2,
        metavar="N",
        help="keep the N most recently used namespaces per repository key (default 2, enough for one per channel)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="remove the namespaces marked REMOVE (default is a dry run)",
    )
    args = parser.parse_args(argv)
    if args.cache_root is None:
        try:
            args.cache_root = absolute_path(
                os.environ.get(CACHE_ROOT_VARIABLE) or str(DEFAULT_CACHE_ROOT)
            )
        except argparse.ArgumentTypeError as error:
            parser.error(f"{CACHE_ROOT_VARIABLE}: {error}")
    return args


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = parse_args(argv)
    except SystemExit as stop:  # argparse has already printed its message
        return stop.code if isinstance(stop.code, int) else EXIT_USAGE
    return prune(args.cache_root, args.keep, apply=args.apply, uid=current_uid())


if __name__ == "__main__":
    raise SystemExit(main())
