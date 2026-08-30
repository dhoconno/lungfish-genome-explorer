#!/usr/bin/env python3
"""Validate every filesystem target a release package operation may mutate."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess

from release_cache_security import CacheSecurityError, validate_ancestor_chain


RELEASE_MARKER = ".lungfish-release-output"
DERIVED_MARKER = ".lungfish-derived-data-output"


class TargetSecurityError(ValueError):
    """A release mutation target is not safe enough for destructive use."""


def _contains(parent: Path, child: Path) -> bool:
    return parent == child or parent in child.parents


def _canonical_target(raw: Path, *, label: str, expected_uid: int) -> Path:
    if not raw.is_absolute():
        raise TargetSecurityError(f"{label} must be absolute")
    canonical = raw.resolve(strict=False)
    if str(raw) != str(canonical):
        raise TargetSecurityError(
            f"{label} must use its canonical path without aliases or symlinks"
        )
    current = Path(raw.anchor)
    for part in raw.parts[1:]:
        candidate = current / part
        if not candidate.exists() and not candidate.is_symlink():
            break
        try:
            exact_names = {entry.name for entry in current.iterdir()}
        except OSError as error:
            raise TargetSecurityError(
                f"{label} ancestor spelling could not be verified"
            ) from error
        if part not in exact_names:
            raise TargetSecurityError(
                f"{label} must use the filesystem's canonical letter case"
            )
        current = candidate
    try:
        validate_ancestor_chain(raw, expected_uid=expected_uid)
    except CacheSecurityError as error:
        raise TargetSecurityError(f"{label} has an unsafe ancestor: {error}") from error
    return canonical


def _private_external_ancestor(path: Path, *, expected_uid: int, label: str) -> None:
    current = path
    while not current.exists():
        if current == current.parent:
            raise TargetSecurityError(f"{label} has no validated private ancestor")
        current = current.parent
    try:
        metadata = current.lstat()
    except OSError as error:
        raise TargetSecurityError(
            f"{label} ancestor metadata is unavailable"
        ) from error
    mode = stat.S_IMODE(metadata.st_mode)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != expected_uid
        or mode & 0o022
    ):
        raise TargetSecurityError(
            f"{label} must be beneath a private directory owned by the release user"
        )


def _validate_existing_output(
    path: Path,
    *,
    label: str,
    marker: str | None = None,
    archive: bool = False,
) -> None:
    if not path.exists():
        return
    if not path.is_dir():
        raise TargetSecurityError(f"existing {label} is not a directory")
    try:
        entries = list(path.iterdir())
    except OSError as error:
        raise TargetSecurityError(f"existing {label} is unreadable") from error
    if not entries:
        return
    if marker is not None:
        marker_path = path / marker
        if marker_path.is_file() and not marker_path.is_symlink():
            return
    if archive:
        applications = path / "Products" / "Applications"
        if applications.is_dir() and any(
            candidate.is_dir() and (candidate / "Contents" / "Info.plist").is_file()
            for candidate in applications.glob("*.app")
        ):
            return
    raise TargetSecurityError(
        f"existing {label} is unrelated to a recognized Lungfish release output"
    )


def validate_release_targets(
    *,
    project_root: Path,
    home: Path,
    scratch_root: Path,
    scratch_path: Path,
    release_dir: Path,
    archive_path: Path,
    derived_data_path: Path,
    repository_key: str,
    commit: str,
    expected_uid: int | None = None,
) -> None:
    """Validate exact package mutation targets without creating or deleting them."""
    uid = os.geteuid() if expected_uid is None else expected_uid
    project = project_root.resolve(strict=True)
    home = home.resolve(strict=True)
    scratch_base = _canonical_target(
        scratch_root, label="scratch root", expected_uid=uid
    )
    targets = {
        "scratch path": _canonical_target(
            scratch_path, label="scratch path", expected_uid=uid
        ),
        "release directory": _canonical_target(
            release_dir, label="release directory", expected_uid=uid
        ),
        "archive path": _canonical_target(
            archive_path, label="archive path", expected_uid=uid
        ),
        "DerivedData path": _canonical_target(
            derived_data_path, label="DerivedData path", expected_uid=uid
        ),
    }
    scratch = targets["scratch path"]
    release = targets["release directory"]
    archive = targets["archive path"]
    derived = targets["DerivedData path"]

    if archive.suffix != ".xcarchive":
        raise TargetSecurityError("archive path must end in .xcarchive")
    if re.fullmatch(r"[0-9a-f]{64}", repository_key) is None:
        raise TargetSecurityError("repository scratch key is invalid")
    if re.fullmatch(r"[0-9a-fA-F]{40}", commit) is None:
        raise TargetSecurityError("repository commit identity is invalid")
    expected_scratch = scratch_base / repository_key / commit.lower()
    if scratch != expected_scratch:
        raise TargetSecurityError(
            "scratch path must match the current repository and commit identity"
        )
    if _contains(home, scratch) or _contains(project, scratch):
        raise TargetSecurityError("scratch path must be outside home and repository")

    forbidden = (Path("/"), home, project)
    for label, target in targets.items():
        if any(_contains(target, boundary) for boundary in forbidden):
            raise TargetSecurityError(
                f"{label} must not be root, home, repository, or their ancestor"
            )

    recognized_repository_targets = {
        ("release directory", project / "build" / "Release"),
        ("archive path", project / "build" / "Release" / "Lungfish.xcarchive"),
        ("DerivedData path", project / ".build" / "release-derived-data"),
    }
    for label, target in targets.items():
        if project in target.parents:
            if (label, target) not in recognized_repository_targets:
                raise TargetSecurityError(
                    f"{label} is an unrecognized repository output path"
                )
        elif label != "scratch path":
            _private_external_ancestor(target, expected_uid=uid, label=label)

    allowed_release_archive_overlap = release in archive.parents
    pairs = (
        ("scratch path", scratch, "release directory", release),
        ("scratch path", scratch, "archive path", archive),
        ("scratch path", scratch, "DerivedData path", derived),
        ("release directory", release, "archive path", archive),
        ("release directory", release, "DerivedData path", derived),
        ("archive path", archive, "DerivedData path", derived),
    )
    for left_label, left, right_label, right in pairs:
        if not (_contains(left, right) or _contains(right, left)):
            continue
        if (
            left_label == "release directory"
            and right_label == "archive path"
            and allowed_release_archive_overlap
        ):
            continue
        raise TargetSecurityError(f"{left_label} overlaps {right_label}")

    release_is_default = release == project / "build" / "Release"
    derived_is_default = derived == project / ".build" / "release-derived-data"
    if not release_is_default:
        _validate_existing_output(
            release, label="release directory", marker=RELEASE_MARKER
        )
    if not derived_is_default:
        _validate_existing_output(
            derived, label="DerivedData path", marker=DERIVED_MARKER
        )
    if not allowed_release_archive_overlap:
        _validate_existing_output(archive, label="archive", archive=True)


def repository_identity(project_root: Path) -> tuple[str, str]:
    remote = subprocess.run(
        ["git", "-C", str(project_root), "config", "--get", "remote.origin.url"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    ).stdout.strip()
    if not remote:
        remote = subprocess.run(
            ["git", "-C", str(project_root), "rev-parse", "--show-toplevel"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=True,
        ).stdout.strip()
    commit = subprocess.run(
        ["git", "-C", str(project_root), "rev-parse", "--verify", "HEAD"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=True,
    ).stdout.strip()
    return hashlib.sha256(remote.encode()).hexdigest(), commit


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--scratch-root", type=Path, required=True)
    parser.add_argument("--scratch-path", type=Path, required=True)
    parser.add_argument("--release-dir", type=Path, required=True)
    parser.add_argument("--archive-path", type=Path, required=True)
    parser.add_argument("--derived-data-path", type=Path, required=True)
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        repository_key, commit = repository_identity(args.project_root)
        validate_release_targets(
            project_root=args.project_root,
            home=args.home,
            scratch_root=args.scratch_root,
            scratch_path=args.scratch_path,
            release_dir=args.release_dir,
            archive_path=args.archive_path,
            derived_data_path=args.derived_data_path,
            repository_key=repository_key,
            commit=commit,
        )
    except (OSError, subprocess.SubprocessError, TargetSecurityError) as error:
        print(f"FAIL mutation targets: {error}")
        return 1
    print("PASS mutation targets: exact package mutation targets are safe")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
