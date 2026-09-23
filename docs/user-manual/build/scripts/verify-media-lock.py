#!/usr/bin/env python3
"""Verify every file named in media.lock against a checked-out media repo.

Usage: verify-media-lock.py <lock-file> <checked-out-media-repo-dir>

Exits non-zero and prints every mismatch (missing file, wrong hash, wrong
size) if verification fails. This is deliberately strict: a single bad file
fails the whole fetch, since a manual build with a silently wrong image is
worse than a build that refuses to run.
"""
import hashlib
import json
import sys
from pathlib import Path


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv):
    if len(argv) != 3:
        print(f"usage: {argv[0]} <lock-file> <media-repo-dir>", file=sys.stderr)
        return 64

    lock_path = Path(argv[1])
    repo_dir = Path(argv[2])

    manifest = json.loads(lock_path.read_text())
    problems = []

    for entry in manifest["files"]:
        rel_path = entry["path"]
        expected_sha256 = entry["sha256"]
        expected_size = entry.get("size")
        candidate = repo_dir / rel_path

        if not candidate.is_file():
            problems.append(f"missing: {rel_path}")
            continue

        actual_size = candidate.stat().st_size
        if expected_size is not None and actual_size != expected_size:
            problems.append(
                f"size mismatch: {rel_path} (expected {expected_size}, got {actual_size})"
            )
            continue

        actual_sha256 = sha256_of(candidate)
        if actual_sha256 != expected_sha256:
            problems.append(
                f"sha256 mismatch: {rel_path} (expected {expected_sha256}, got {actual_sha256})"
            )

    if problems:
        print(f"verify-media-lock.py: {len(problems)} problem(s):", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    print(f"verify-media-lock.py: {len(manifest['files'])} files verified OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
