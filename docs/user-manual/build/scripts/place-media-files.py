#!/usr/bin/env python3
"""Copy verified media-repo files to the paths the manual build/chapters use.

Usage: place-media-files.py <lock-file> <checked-out-media-repo-dir> <docs/user-manual dir>

Every entry in media.lock has a path like "user-manual/assets/screenshots/...".
This strips the leading "user-manual/" and copies the file to the same
relative path under the given docs/user-manual directory, so
"assets/illustrations-imagegen/.../foo.png" lands at
"<docs/user-manual>/assets/illustrations-imagegen/.../foo.png" - exactly
where chapters and illustrations.yaml already reference it.
"""
import json
import shutil
import sys
from pathlib import Path

PREFIX = "user-manual/"


def main(argv):
    if len(argv) != 4:
        print(f"usage: {argv[0]} <lock-file> <media-repo-dir> <manual-root>", file=sys.stderr)
        return 64

    lock_path = Path(argv[1])
    repo_dir = Path(argv[2])
    manual_root = Path(argv[3])

    manifest = json.loads(lock_path.read_text())
    placed = 0

    for entry in manifest["files"]:
        rel_path = entry["path"]
        if not rel_path.startswith(PREFIX):
            print(f"place-media-files.py: skipping unexpected path (no {PREFIX!r} prefix): {rel_path}", file=sys.stderr)
            continue

        source = repo_dir / rel_path
        destination = manual_root / rel_path[len(PREFIX):]
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        placed += 1

    print(f"place-media-files.py: placed {placed} files under {manual_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
