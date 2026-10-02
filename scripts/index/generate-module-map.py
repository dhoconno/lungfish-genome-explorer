#!/usr/bin/env python3
"""generate-module-map.py - Emit docs/architecture/MODULES.md from Package.swift
and the Sources tree.

Background (2026-10-02 architecture review, finding R5): agents had no module
map, so every session paid a discovery tax of directory listings and greps.
This script produces a deterministic index of every SwiftPM target with

  - its kind, path and internal and external dependencies
  - the targets that depend on it
  - Swift file and line counts, overall and per subdirectory (two levels)
  - every public or open top-level type with its file and line
  - the test targets that depend on it directly

Package.swift is parsed with a small pure-Python reader (no `swift package
dump-package`, so no .build lock is taken). The reader understands the subset
of the manifest DSL this repository uses: `.target`, `.testTarget` and
`.executableTarget` calls with `name:`, `dependencies:` and `path:`
arguments, where a dependency is a string literal (an internal target) or a
`.product(name:package:)` call (an external product).

Output is sorted and carries no timestamps, so running the script twice
yields byte-identical files.

Usage:
    scripts/index/generate-module-map.py                 # write docs/architecture/MODULES.md
    scripts/index/generate-module-map.py --stdout        # print instead of writing
    scripts/index/generate-module-map.py --output PATH   # write somewhere else
    scripts/index/generate-module-map.py --root PATH     # use another repository root

Python 3 standard library only.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = Path("docs/architecture/MODULES.md")

TARGET_KINDS = {
    "target": "library",
    "testTarget": "test",
    "executableTarget": "executable",
}

# A public or open declaration at column 0 (top level). Attributes such as
# @MainActor or @available(...) may precede it on the same line, and
# modifiers such as final, indirect or nonisolated may appear in any order.
PUBLIC_TYPE_RE = re.compile(
    r"^(?:@[A-Za-z_][A-Za-z0-9_.]*(?:\([^)]*\))?\s+)*"
    r"(?:(?:final|indirect|nonisolated|nonisolated\(unsafe\)|sending)\s+)*"
    r"(?:public|open)\s+"
    r"(?:(?:final|indirect|nonisolated)\s+)*"
    r"(class|struct|enum|protocol|actor|typealias)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)"
)


@dataclass
class Target:
    name: str
    kind: str
    path: str
    internal_deps: list[str] = field(default_factory=list)
    external_deps: list[str] = field(default_factory=list)


@dataclass
class PublicType:
    name: str
    kind: str
    file: str
    line: int


# ---------------------------------------------------------------------------
# Package.swift parsing
# ---------------------------------------------------------------------------

def strip_comments(text: str) -> str:
    """Remove // and /* */ comments while leaving string literals intact."""
    out: list[str] = []
    i = 0
    n = len(text)
    in_string = False
    while i < n:
        ch = text[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if text.startswith("//", i):
            end = text.find("\n", i)
            if end == -1:
                break
            i = end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end == -1:
                break
            i = end + 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def balanced_span(text: str, open_index: int) -> int:
    """Return the index just past the bracket that closes text[open_index]."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack: list[str] = []
    i = open_index
    in_string = False
    while i < len(text):
        ch = text[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
        elif ch in pairs:
            stack.append(pairs[ch])
        elif stack and ch == stack[-1]:
            stack.pop()
            if not stack:
                return i + 1
        i += 1
    raise ValueError(f"unbalanced bracket starting at offset {open_index}")


def argument_value(body: str, label: str) -> str | None:
    """Return the raw text of a top-level `label:` argument inside a call body."""
    depth = 0
    i = 0
    in_string = False
    pattern = re.compile(rf"\b{re.escape(label)}\s*:")
    while i < len(body):
        ch = body[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif depth == 0:
            m = pattern.match(body, i)
            if m and (i == 0 or not (body[i - 1].isalnum() or body[i - 1] == "_")):
                start = m.end()
                while start < len(body) and body[start].isspace():
                    start += 1
                if start < len(body) and body[start] in "([{":
                    end = balanced_span(body, start)
                    return body[start:end]
                end = start
                local_string = False
                while end < len(body):
                    c = body[end]
                    if local_string:
                        if c == "\\":
                            end += 2
                            continue
                        if c == '"':
                            local_string = False
                    elif c == '"':
                        local_string = True
                    elif c == ",":
                        break
                    end += 1
                return body[start:end].strip()
        i += 1
    return None


def string_literal(raw: str | None) -> str | None:
    if raw is None:
        return None
    m = re.fullmatch(r'\s*"((?:[^"\\]|\\.)*)"\s*', raw)
    return m.group(1) if m else None


def split_top_level(list_text: str) -> list[str]:
    """Split the inside of a [ ... ] literal on top-level commas."""
    inner = list_text.strip()
    if inner.startswith("[") and inner.endswith("]"):
        inner = inner[1:-1]
    items: list[str] = []
    depth = 0
    current: list[str] = []
    in_string = False
    i = 0
    while i < len(inner):
        ch = inner[i]
        if in_string:
            current.append(ch)
            if ch == "\\" and i + 1 < len(inner):
                current.append(inner[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
            current.append(ch)
        elif ch in "([{":
            depth += 1
            current.append(ch)
        elif ch in ")]}":
            depth -= 1
            current.append(ch)
        elif ch == "," and depth == 0:
            items.append("".join(current).strip())
            current = []
        else:
            current.append(ch)
        i += 1
    tail = "".join(current).strip()
    if tail:
        items.append(tail)
    return [item for item in items if item]


def parse_dependencies(raw: str | None) -> tuple[list[str], list[str]]:
    internal: list[str] = []
    external: list[str] = []
    if raw is None:
        return internal, external
    for item in split_top_level(raw):
        literal = string_literal(item)
        if literal is not None:
            internal.append(literal)
            continue
        m = re.match(r"\.(product|target|byName)\s*\(", item)
        if not m:
            raise ValueError(f"unrecognised dependency entry: {item!r}")
        body = item[item.index("(") + 1 : balanced_span(item, item.index("(")) - 1]
        name = string_literal(argument_value(body, "name"))
        if name is None:
            raise ValueError(f"dependency without a name: {item!r}")
        if m.group(1) == "product":
            package = string_literal(argument_value(body, "package"))
            external.append(f"{name} ({package})" if package else name)
        else:
            internal.append(name)
    return internal, external


def parse_package(manifest_text: str) -> list[Target]:
    text = strip_comments(manifest_text)
    targets: list[Target] = []
    call_re = re.compile(r"\.(target|testTarget|executableTarget)\s*\(")
    consumed_until = 0
    for m in call_re.finditer(text):
        if m.start() < consumed_until:
            # A `.target(name:)` dependency nested inside another target.
            continue
        open_index = m.end() - 1
        end = balanced_span(text, open_index)
        body = text[open_index + 1 : end - 1]
        name = string_literal(argument_value(body, "name"))
        if name is None:
            continue
        consumed_until = end
        kind = TARGET_KINDS[m.group(1)]
        path = string_literal(argument_value(body, "path"))
        if path is None:
            path = f"Tests/{name}" if kind == "test" else f"Sources/{name}"
        internal, external = parse_dependencies(argument_value(body, "dependencies"))
        targets.append(Target(name, kind, path.rstrip("/"), internal, external))
    names = [t.name for t in targets]
    if len(names) != len(set(names)):
        raise ValueError("duplicate target names in Package.swift")
    return targets


# ---------------------------------------------------------------------------
# Sources walking
# ---------------------------------------------------------------------------

def swift_files(root: Path, rel_dir: str) -> list[str]:
    base = root / rel_dir
    found: list[str] = []
    if not base.is_dir():
        return found
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for filename in sorted(filenames):
            if filename.endswith(".swift"):
                full = Path(dirpath) / filename
                found.append(full.relative_to(root).as_posix())
    return sorted(found)


def line_count(path: Path) -> int:
    data = path.read_bytes()
    if not data:
        return 0
    count = data.count(b"\n")
    if not data.endswith(b"\n"):
        count += 1
    return count


def public_types(root: Path, files: list[str]) -> list[PublicType]:
    result: list[PublicType] = []
    for rel in files:
        text = (root / rel).read_text(encoding="utf-8", errors="replace")
        for number, line in enumerate(text.splitlines(), start=1):
            m = PUBLIC_TYPE_RE.match(line)
            if m:
                result.append(PublicType(m.group(2), m.group(1), rel, number))
    result.sort(key=lambda t: (t.name.lower(), t.name, t.file, t.line))
    return result


def subdirectory_stats(
    target_path: str, files: list[str], counts: dict[str, int]
) -> list[tuple[str, int, int]]:
    """Return (relative subdirectory, files, lines) for one and two levels deep."""
    stats: dict[str, list[int]] = {}
    prefix = target_path + "/"
    for rel in files:
        inner = rel[len(prefix) :] if rel.startswith(prefix) else rel
        parts = inner.split("/")[:-1]
        for depth in (1, 2):
            if len(parts) >= depth:
                key = "/".join(parts[:depth])
                entry = stats.setdefault(key, [0, 0])
                entry[0] += 1
                entry[1] += counts[rel]
    return sorted((k, v[0], v[1]) for k, v in stats.items())


# ---------------------------------------------------------------------------
# Rendering
#
# Tables use plain `---` separators because the manual prose lint counts a
# right-align `---:` delimiter as a sentence colon.
# ---------------------------------------------------------------------------

def render(root: Path) -> str:
    manifest = (root / "Package.swift").read_text(encoding="utf-8")
    targets = parse_package(manifest)
    by_name = {t.name: t for t in targets}
    internal_names = set(by_name)

    dependents: dict[str, list[str]] = {t.name: [] for t in targets}
    for t in targets:
        for dep in t.internal_deps:
            if dep in dependents:
                dependents[dep].append(t.name)

    source_targets = sorted(
        (t for t in targets if t.kind != "test" and t.path.startswith("Sources/")),
        key=lambda t: t.name,
    )
    support_targets = sorted(
        (t for t in targets if t.kind != "test" and not t.path.startswith("Sources/")),
        key=lambda t: t.name,
    )
    test_targets = sorted((t for t in targets if t.kind == "test"), key=lambda t: t.name)

    file_lists: dict[str, list[str]] = {}
    line_counts: dict[str, int] = {}
    for t in targets:
        files = swift_files(root, t.path)
        file_lists[t.name] = files
        for rel in files:
            line_counts[rel] = line_count(root / rel)

    type_lists = {t.name: public_types(root, file_lists[t.name]) for t in source_targets + support_targets}

    def total_lines(name: str) -> int:
        return sum(line_counts[f] for f in file_lists[name])

    out: list[str] = []
    w = out.append
    w("# Module map")
    w("")
    w("Generated by scripts/index/generate-module-map.py from Package.swift and the Sources tree. Do not edit by hand.")
    w("Regenerate with `python3 scripts/index/generate-module-map.py` and check currency with `python3 scripts/checks/module-map-current.py`.")
    w("")
    w("Counts cover Swift files only. Public types are top-level `public` or `open` declarations found at column 0.")
    w("")

    w("## Summary")
    w("")
    w("| Target | Kind | Path | Swift files | Lines | Public types | Internal dependencies |")
    w("|---|---|---|---|---|---|---|")
    for t in source_targets + support_targets:
        deps = ", ".join(sorted(d for d in t.internal_deps if d in internal_names)) or "none"
        n_public = len(type_lists[t.name])
        w(
            f"| {t.name} | {t.kind} | {t.path} | {len(file_lists[t.name])} | "
            f"{total_lines(t.name)} | {n_public} | {deps} |"
        )
    w("")

    w("## Test targets")
    w("")
    w("| Test target | Path | Swift files | Lines | Internal dependencies |")
    w("|---|---|---|---|---|")
    for t in test_targets:
        deps = ", ".join(sorted(d for d in t.internal_deps if d in internal_names)) or "none"
        w(f"| {t.name} | {t.path} | {len(file_lists[t.name])} | {total_lines(t.name)} | {deps} |")
    w("")

    for t in source_targets + support_targets:
        files = file_lists[t.name]
        w(f"## {t.name}")
        w("")
        w(f"- Kind. {t.kind}")
        w(f"- Path. {t.path}")
        w(f"- Swift files. {len(files)}, lines {total_lines(t.name)}")
        internal = sorted(d for d in t.internal_deps if d in internal_names)
        w(f"- Depends on. {', '.join(internal) if internal else 'none'}")
        external = sorted(t.external_deps)
        w(f"- External products. {', '.join(external) if external else 'none'}")
        users = sorted(dependents[t.name])
        non_test_users = [u for u in users if by_name[u].kind != "test"]
        test_users = [u for u in users if by_name[u].kind == "test"]
        w(f"- Used by. {', '.join(non_test_users) if non_test_users else 'none'}")
        primary = f"{t.name}Tests"
        if primary in test_users:
            others = [u for u in test_users if u != primary]
            line = f"- Test target. {primary}"
            if others:
                line += f" (also tested by {', '.join(others)})"
        elif test_users:
            line = f"- Test target. none named {primary}, tested by {', '.join(test_users)}"
        else:
            line = "- Test target. none"
        w(line)
        w("")

        subdirs = subdirectory_stats(t.path, files, line_counts)
        if subdirs:
            w("### Subdirectories")
            w("")
            w("| Subdirectory | Swift files | Lines |")
            w("|---|---|---|")
            for rel, n_files, n_lines in subdirs:
                w(f"| {rel} | {n_files} | {n_lines} |")
            w("")

        types = type_lists[t.name]
        w("### Public types")
        w("")
        if types:
            for pt in types:
                w(f"- `{pt.name}` {pt.kind}, `{pt.file}:{pt.line}`")
        else:
            w("None.")
        w("")

    return "\n".join(out).rstrip("\n") + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--stdout", action="store_true")
    args = parser.parse_args(argv)

    root = args.root.resolve()
    content = render(root)
    if args.stdout:
        sys.stdout.write(content)
        return 0
    output = args.output if args.output is not None else root / DEFAULT_OUTPUT
    output.parent.mkdir(parents=True, exist_ok=True)
    existing = output.read_text(encoding="utf-8") if output.exists() else None
    if existing != content:
        output.write_text(content, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
