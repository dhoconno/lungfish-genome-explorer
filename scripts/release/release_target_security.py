#!/usr/bin/env python3
"""Validate every filesystem target a release package operation may mutate."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

from release_cache_security import CacheSecurityError, validate_ancestor_chain
from release_repository import RepositoryIdentityError, resolve_repository_identity


RELEASE_MARKER = ".lungfish-release-output"
DERIVED_MARKER = ".lungfish-derived-data-output"
ARCHIVE_MARKER = ".lungfish-release-archive.json"
ARCHIVE_OUTPUT_TYPE = "lungfish-xcarchive"
RELEASE_OUTPUT_TYPE = "lungfish-release-output"


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
    raise TargetSecurityError(
        f"existing {label} is unrelated to a recognized Lungfish release output"
    )


def _validate_existing_archive(
    path: Path, *, repository_key: str, expected_uid: int
) -> None:
    if not path.exists():
        return
    if not path.is_dir():
        raise TargetSecurityError("existing archive is not a directory")
    try:
        entries = list(path.iterdir())
    except OSError as error:
        raise TargetSecurityError("existing archive is unreadable") from error
    if not entries:
        return

    expected = {
        "schemaVersion": 1,
        "outputType": ARCHIVE_OUTPUT_TYPE,
        "repositoryKey": repository_key,
    }
    _validate_private_marker(
        path / ARCHIVE_MARKER,
        expected=expected,
        expected_uid=expected_uid,
        label="archive",
    )


def _validate_private_marker(
    marker: Path,
    *,
    expected: dict[str, object],
    expected_uid: int,
    label: str,
) -> None:
    try:
        metadata = marker.lstat()
    except OSError as error:
        raise TargetSecurityError(
            f"{label} lacks its private Lungfish ownership marker"
        ) from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != expected_uid
        or stat.S_IMODE(metadata.st_mode) != 0o600
    ):
        raise TargetSecurityError(f"{label} ownership marker is unsafe")
    try:
        payload = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise TargetSecurityError(f"{label} ownership marker is invalid") from error
    if payload != expected:
        raise TargetSecurityError(
            f"{label} ownership marker does not match this output"
        )


def validate_release_output_marker(
    release_dir: Path,
    *,
    repository_key: str,
    expected_uid: int | None = None,
) -> None:
    """Require a private marker bound to this repository and canonical directory."""
    uid = os.geteuid() if expected_uid is None else expected_uid
    if re.fullmatch(r"[0-9a-f]{64}", repository_key) is None:
        raise TargetSecurityError("repository release key is invalid")
    canonical = _canonical_target(
        release_dir, label="release directory", expected_uid=uid
    )
    try:
        metadata = canonical.lstat()
    except OSError as error:
        raise TargetSecurityError("release directory is unavailable") from error
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != uid
        or stat.S_IMODE(metadata.st_mode) & 0o022
    ):
        raise TargetSecurityError("release directory ownership is unsafe")
    expected = {
        "schemaVersion": 1,
        "outputType": RELEASE_OUTPUT_TYPE,
        "repositoryKey": repository_key,
        "releaseDir": str(canonical),
    }
    _validate_private_marker(
        canonical / RELEASE_MARKER,
        expected=expected,
        expected_uid=uid,
        label="release directory",
    )


def validate_signed_app_target(
    release_dir: Path,
    signed_app_path: Path,
    *,
    repository_key: str,
    expected_uid: int | None = None,
) -> None:
    """Require a canonical signed-app leaf below a private owned parent."""
    uid = os.geteuid() if expected_uid is None else expected_uid
    validate_release_output_marker(
        release_dir, repository_key=repository_key, expected_uid=uid
    )
    release = release_dir.resolve(strict=True)
    expected_parent = release / "signed"
    if signed_app_path.parent != expected_parent or not signed_app_path.name.endswith(
        ".app"
    ):
        raise TargetSecurityError(
            "signed app must be an exact child of the marked release signed directory"
        )
    canonical = _canonical_target(signed_app_path, label="signed app", expected_uid=uid)
    if canonical.parent != expected_parent:
        raise TargetSecurityError("signed app escapes the marked release directory")
    if expected_parent.exists() or expected_parent.is_symlink():
        try:
            parent_metadata = expected_parent.lstat()
        except OSError as error:
            raise TargetSecurityError(
                "signed app parent metadata is unavailable"
            ) from error
        if (
            not stat.S_ISDIR(parent_metadata.st_mode)
            or stat.S_ISLNK(parent_metadata.st_mode)
            or parent_metadata.st_uid != uid
            or stat.S_IMODE(parent_metadata.st_mode) & 0o077
        ):
            raise TargetSecurityError(
                "signed app parent must be a private owner-controlled directory"
            )
    if signed_app_path.exists() or signed_app_path.is_symlink():
        try:
            app_metadata = signed_app_path.lstat()
        except OSError as error:
            raise TargetSecurityError("signed app metadata is unavailable") from error
        if not stat.S_ISDIR(app_metadata.st_mode) or stat.S_ISLNK(app_metadata.st_mode):
            raise TargetSecurityError("signed app must be a non-symlink directory")


def _write_private_marker(path: Path, payload: dict[str, object]) -> None:
    temporary: Path | None = None
    try:
        descriptor, raw_temporary = tempfile.mkstemp(
            prefix=f".{path.name}.tmp-", dir=path.parent
        )
        temporary = Path(raw_temporary)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        if path.is_symlink():
            raise TargetSecurityError("ownership marker must not be a symlink")
        os.replace(temporary, path)
        temporary = None
    except OSError as error:
        raise TargetSecurityError("ownership marker could not be written") from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def write_release_output_marker(
    release_dir: Path,
    *,
    repository_key: str,
    expected_uid: int | None = None,
) -> None:
    """Atomically bind a validated release directory to its exact canonical path."""
    uid = os.geteuid() if expected_uid is None else expected_uid
    if re.fullmatch(r"[0-9a-f]{64}", repository_key) is None:
        raise TargetSecurityError("repository release key is invalid")
    canonical = _canonical_target(
        release_dir, label="release directory", expected_uid=uid
    )
    try:
        metadata = canonical.lstat()
    except OSError as error:
        raise TargetSecurityError("new release directory is unavailable") from error
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != uid:
        raise TargetSecurityError("new release directory ownership is unsafe")
    payload = {
        "schemaVersion": 1,
        "outputType": RELEASE_OUTPUT_TYPE,
        "repositoryKey": repository_key,
        "releaseDir": str(canonical),
    }
    _write_private_marker(canonical / RELEASE_MARKER, payload)
    validate_release_output_marker(
        canonical, repository_key=repository_key, expected_uid=uid
    )


def write_archive_marker(
    archive_path: Path,
    *,
    repository_key: str,
    expected_uid: int | None = None,
) -> None:
    """Atomically bind a newly created archive to this repository."""
    uid = os.geteuid() if expected_uid is None else expected_uid
    if re.fullmatch(r"[0-9a-f]{64}", repository_key) is None:
        raise TargetSecurityError("repository archive key is invalid")
    try:
        archive_metadata = archive_path.lstat()
    except OSError as error:
        raise TargetSecurityError("new archive is unavailable") from error
    if (
        not stat.S_ISDIR(archive_metadata.st_mode)
        or archive_metadata.st_uid != uid
        or archive_path.is_symlink()
    ):
        raise TargetSecurityError("new archive ownership is unsafe")

    payload = {
        "schemaVersion": 1,
        "outputType": ARCHIVE_OUTPUT_TYPE,
        "repositoryKey": repository_key,
    }
    _write_private_marker(archive_path / ARCHIVE_MARKER, payload)
    _validate_private_marker(
        archive_path / ARCHIVE_MARKER,
        expected=payload,
        expected_uid=uid,
        label="archive",
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
    cache_fingerprint = scratch.parent.name
    if re.fullmatch(r"[0-9a-f]{64}", cache_fingerprint) is None:
        raise TargetSecurityError("release cache fingerprint is invalid")
    expected_namespace = scratch_base / "v1" / repository_key / cache_fingerprint
    expected_scratch = expected_namespace / "swiftpm"
    if scratch != expected_scratch:
        raise TargetSecurityError(
            "scratch path must match the repository and cache fingerprint identity"
        )
    if derived != expected_namespace / "derived-data":
        raise TargetSecurityError(
            "DerivedData path must share the exact cache fingerprint namespace"
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
    }
    scoped_repository_targets: set[tuple[str, Path]] = set()
    scoped_triples: list[tuple[Path, Path, Path]] = []
    for channel in ("preview", "stable"):
        scoped_release = project / "build" / "Release" / channel / commit.lower()
        scoped_archive = scoped_release / "Lungfish.xcarchive"
        scoped_derived = expected_namespace / "derived-data"
        scoped_triples.append((scoped_release, scoped_archive, scoped_derived))
        scoped_repository_targets.update(
            {
                ("release directory", scoped_release),
                ("archive path", scoped_archive),
                ("DerivedData path", scoped_derived),
            }
        )
    recognized_repository_targets.update(scoped_repository_targets)
    uses_scoped_target = any(
        (label, target) in scoped_repository_targets
        for label, target in (
            ("release directory", release),
            ("archive path", archive),
        )
    )
    if uses_scoped_target and (release, archive, derived) not in scoped_triples:
        raise TargetSecurityError(
            "scoped release outputs must use the same channel and commit"
        )
    for label, target in targets.items():
        if project in target.parents:
            if (label, target) not in recognized_repository_targets:
                raise TargetSecurityError(
                    f"{label} is an unrecognized repository output path"
                )
        elif label not in ("scratch path", "DerivedData path"):
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

    if release.exists() and any(release.iterdir()):
        validate_release_output_marker(
            release, repository_key=repository_key, expected_uid=uid
        )
    if not allowed_release_archive_overlap:
        _validate_existing_archive(
            archive, repository_key=repository_key, expected_uid=uid
        )


def repository_identity(project_root: Path, remote: str) -> tuple[str, str]:
    identity = resolve_repository_identity(project_root, remote)
    commit = subprocess.run(
        ["git", "-C", str(project_root), "rev-parse", "--verify", "HEAD"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=True,
    ).stdout.strip()
    return identity.repository_key, commit


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--scratch-root", type=Path, required=True)
    parser.add_argument("--scratch-path", type=Path, required=True)
    parser.add_argument("--release-dir", type=Path, required=True)
    parser.add_argument("--archive-path", type=Path, required=True)
    parser.add_argument("--derived-data-path", type=Path, required=True)
    parser.add_argument("--remote", default="origin")
    return parser


def _record_archive_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=write_archive_marker.__doc__)
    parser.add_argument("--archive-path", type=Path, required=True)
    parser.add_argument("--repository-key", required=True)
    return parser


def _release_marker_parser(description: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--release-dir", type=Path, required=True)
    parser.add_argument("--repository-key", required=True)
    return parser


def _signed_output_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=validate_signed_app_target.__doc__)
    parser.add_argument("--release-dir", type=Path, required=True)
    parser.add_argument("--signed-app-path", type=Path, required=True)
    parser.add_argument("--repository-key", required=True)
    return parser


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "validate-signed-output":
        args = _signed_output_parser().parse_args(sys.argv[2:])
        try:
            validate_signed_app_target(
                args.release_dir,
                args.signed_app_path,
                repository_key=args.repository_key,
            )
        except TargetSecurityError as error:
            print(f"FAIL signed output: {error}")
            return 1
        print("PASS signed output: canonical private target verified")
        return 0
    if len(sys.argv) > 1 and sys.argv[1] == "record-archive":
        args = _record_archive_parser().parse_args(sys.argv[2:])
        try:
            write_archive_marker(args.archive_path, repository_key=args.repository_key)
        except TargetSecurityError as error:
            print(f"FAIL archive marker: {error}")
            return 1
        print("PASS archive marker: repository ownership recorded")
        return 0
    if len(sys.argv) > 1 and sys.argv[1] in (
        "record-release-output",
        "validate-release-output",
    ):
        operation = sys.argv[1]
        args = _release_marker_parser(
            "Record or validate a path-bound Lungfish release output marker."
        ).parse_args(sys.argv[2:])
        try:
            if operation == "record-release-output":
                write_release_output_marker(
                    args.release_dir, repository_key=args.repository_key
                )
            else:
                validate_release_output_marker(
                    args.release_dir, repository_key=args.repository_key
                )
        except TargetSecurityError as error:
            print(f"FAIL release marker: {error}")
            return 1
        print(f"PASS release marker: {operation} verified")
        return 0
    args = _parser().parse_args()
    try:
        repository_key, commit = repository_identity(args.project_root, args.remote)
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
    except (
        OSError,
        RepositoryIdentityError,
        subprocess.SubprocessError,
        TargetSecurityError,
    ) as error:
        print(f"FAIL mutation targets: {error}")
        return 1
    print("PASS mutation targets: exact package mutation targets are safe")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
