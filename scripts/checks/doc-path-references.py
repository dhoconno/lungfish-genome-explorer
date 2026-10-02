#!/usr/bin/env python3
"""doc-path-references.py - Verify that Swift file references in agent-facing docs resolve.

The architecture program (review finding R5) relies on AGENTS.md files, the
architecture docs, the contracts and the agent role prompts naming real files.
Documentation that cites a file that was renamed or deleted sends the next agent
to the wrong place. This check scans these docs for `*.swift` references and
fails when one does not resolve:

  AGENTS.md (root), Sources/*/AGENTS.md, Tests/AGENTS.md,
  docs/architecture/**/*.md, docs/contracts/**/*.md,
  agents/process/**/*.md, agents/specialists/**/*.md

Resolution rules for a reference token ending in `.swift`:
  - URLs (`scheme://...`) are removed from a line before it is scanned, so a link
    such as https://docs.swift.org/... is never read as a file name.
  - Tokens containing `<`, `>`, `*`, `{`, `}` or `..` are placeholders and skipped.
  - A path starting with `Sources/` or `Tests/` must exist relative to the repo root.
  - Any other path with a slash resolves relative to the repo root, relative to the
    doc's own module directory (Sources/Foo/ for Sources/Foo/AGENTS.md, Tests/ for
    Tests/AGENTS.md), or as a trailing path of any indexed Swift file.
  - A bare `Foo.swift` name resolves when any file of that name exists in the repo.
    The index skips .build, .git, .claude, worktrees and node_modules.
  - Names listed in scripts/checks/doc-path-references.allowlist are skipped. One
    entry per line as `<token>  # reason`. Use it only for intentionally
    hypothetical files (a contract's "new file" example).

Usage:
    scripts/checks/doc-path-references.py
    scripts/checks/doc-path-references.py --root DIR --allowlist FILE

Exit codes: 0 = every reference resolves, 1 = at least one does not.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ALLOWLIST = Path(__file__).resolve().with_suffix(".allowlist")
SKIP_DIRS = {".build", ".git", ".claude", "worktrees", "node_modules", ".swiftpm"}
TOKEN = re.compile(r"[A-Za-z0-9_+./<>*{}@~-]+\.swift\b")
PLACEHOLDER = re.compile(r"[<>*{}]|\.\.")
URL = re.compile(r"\b[A-Za-z][A-Za-z0-9+.-]*://\S+")
DOC_TREES = ("docs/architecture", "docs/contracts", "agents/process", "agents/specialists")


def index_swift_files(root: Path):
    """Return (names, rel_paths) for every .swift file in the repo."""
    names: set[str] = set()
    paths: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn.endswith(".swift"):
                names.add(fn)
                rel = (Path(dirpath) / fn).relative_to(root).as_posix()
                paths.append(rel)
    return names, paths


def read_allowlist(path: Path) -> set[str]:
    entries: set[str] = set()
    if not path.exists():
        return entries
    for line in path.read_text(encoding="utf-8").splitlines():
        entry = line.split("#", 1)[0].strip()
        if entry:
            entries.add(entry)
    return entries


def checked_docs(root: Path) -> list[Path]:
    docs: list[Path] = []
    if (root / "AGENTS.md").is_file():
        docs.append(root / "AGENTS.md")
    docs += sorted((root / "Sources").glob("*/AGENTS.md"))
    if (root / "Tests" / "AGENTS.md").is_file():
        docs.append(root / "Tests" / "AGENTS.md")
    for sub in DOC_TREES:
        docs += sorted((root / sub).rglob("*.md"))
    return docs


def module_dir(doc: Path, root: Path) -> Path | None:
    rel = doc.relative_to(root)
    if rel.name == "AGENTS.md" and len(rel.parts) >= 2 and rel.parts[0] in ("Sources", "Tests"):
        return doc.parent
    return None


def resolves(token: str, doc: Path, root: Path, names: set[str], paths: list[str]) -> bool:
    if token.startswith("./"):
        token = token[2:]
    if "/" not in token:
        return token in names
    if token.startswith(("Sources/", "Tests/")):
        return (root / token).is_file()
    if (root / token).is_file():
        return True
    mod = module_dir(doc, root)
    if mod is not None and (mod / token).is_file():
        return True
    suffix = "/" + token
    return any(p.endswith(suffix) for p in paths)


def check(docs: list[Path], root: Path, names, paths, allow: set[str]):
    problems = []
    for doc in docs:
        rel = doc.relative_to(root).as_posix()
        text = doc.read_text(encoding="utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            for m in TOKEN.finditer(URL.sub(" ", line)):
                token = m.group(0).strip(".")
                if PLACEHOLDER.search(token) or token in allow:
                    continue
                if not resolves(token, doc, root, names, paths):
                    problems.append((rel, lineno, token))
    return problems


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--allowlist", type=Path, default=DEFAULT_ALLOWLIST)
    args = parser.parse_args(argv)
    root = args.root.resolve()

    names, paths = index_swift_files(root)
    allow = read_allowlist(args.allowlist)

    problems = check(checked_docs(root), root, names, paths, allow)
    if problems:
        print(f"doc-path-references: {len(problems)} reference(s) do not resolve to a Swift file:", file=sys.stderr)
        for rel, lineno, token in problems:
            print(f"  {rel}:{lineno}: {token}", file=sys.stderr)
        print(
            "Fix the doc, or for an intentionally hypothetical file add it with a reason to "
            "scripts/checks/doc-path-references.allowlist.",
            file=sys.stderr,
        )
        return 1

    print("doc-path-references: every Swift file reference in the checked docs resolves.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
