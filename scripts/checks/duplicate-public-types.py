#!/usr/bin/env python3
"""duplicate-public-types.py - Public and open type names must be unique across Sources targets.

Two modules that each declare `public enum SequencingPlatform` force every file
that imports both to qualify the name, and let the two definitions drift apart
(review finding R15). This check collects every top-level `public` or `open`
class, struct, enum, actor, protocol and typealias declaration under
Sources/<Target>/ (declarations at column 0, so nested types are not compared)
and fails when one name is declared in more than one target.

Known duplicates are listed in scripts/checks/duplicate-public-types.allowlist,
one entry per line as `<TypeName>  # reason`. Remove an entry when the duplicate
is resolved. An allowlist entry for a name that is no longer duplicated is
reported as stale (warning, exit 0).

Usage:
    scripts/checks/duplicate-public-types.py
    scripts/checks/duplicate-public-types.py --root DIR --allowlist FILE

Exit codes: 0 = no unlisted duplicate, 1 = at least one unlisted duplicate.
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ALLOWLIST = Path(__file__).resolve().with_suffix(".allowlist")

DECL = re.compile(
    r"^(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"(?:public|open)\s+(?:(?:final|indirect)\s+)*"
    r"(?:class|struct|enum|actor|protocol|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)"
)


def collect(root: Path) -> dict[str, list[tuple[str, str, int]]]:
    """name -> [(target, relative path, line)]"""
    found: dict[str, list[tuple[str, str, int]]] = defaultdict(list)
    sources = root / "Sources"
    if not sources.is_dir():
        return found
    for target_dir in sorted(p for p in sources.iterdir() if p.is_dir()):
        for path in sorted(target_dir.rglob("*.swift")):
            text = path.read_text(encoding="utf-8", errors="replace")
            for lineno, line in enumerate(text.splitlines(), 1):
                m = DECL.match(line)
                if m:
                    found[m.group(1)].append(
                        (target_dir.name, path.relative_to(root).as_posix(), lineno)
                    )
    return found


def read_allowlist(path: Path) -> set[str]:
    entries: set[str] = set()
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            entry = line.split("#", 1)[0].strip()
            if entry:
                entries.add(entry)
    return entries


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--allowlist", type=Path, default=DEFAULT_ALLOWLIST)
    args = parser.parse_args(argv)
    root = args.root.resolve()

    allow = read_allowlist(args.allowlist)
    found = collect(root)
    duplicates = {
        name: sites for name, sites in found.items() if len({t for t, _, _ in sites}) > 1
    }

    stale = sorted(allow - set(duplicates))
    for name in stale:
        print(f"duplicate-public-types: allowlist entry {name} is no longer a duplicate; remove it.")

    unlisted = {n: s for n, s in duplicates.items() if n not in allow}
    if unlisted:
        print(
            f"duplicate-public-types: {len(unlisted)} public type name(s) declared in more than one target:",
            file=sys.stderr,
        )
        for name in sorted(unlisted):
            print(f"  {name}", file=sys.stderr)
            for target, rel, lineno in unlisted[name]:
                print(f"    {rel}:{lineno} ({target})", file=sys.stderr)
        print(
            "Rename one declaration or move it to a shared module. For a known duplicate with a "
            "scheduled fix, add it with a reason to scripts/checks/duplicate-public-types.allowlist.",
            file=sys.stderr,
        )
        return 1

    print(
        f"duplicate-public-types: no unlisted duplicates ({len(duplicates)} allowlisted) "
        f"across {len(found)} public type names."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
