#!/usr/bin/env python3
"""Census of oversized Swift files that hold several top-level types (finding R6).

Usage: type_census.py <repo> [--min-lines 800]

Lists Swift files under Sources longer than --min-lines that declare more
than one distinct top-level type (class, struct, enum, protocol, actor),
counting extensions of a type declared in the same file as part of it.
Marks each file SKIP when a test reads it as source text: its repo path,
its file name, or its directory plus name appears in a string literal under
Tests. Prints a TSV: status, lines, type count, path, type names.
"""
import re
import sys
from pathlib import Path

DECL = re.compile(
    r"^(?:@[\w().:, ]+\s+)*(?:(?:public|internal|fileprivate|private|open|final|indirect|nonisolated)\s+)*"
    r"(class|struct|enum|protocol|actor)\s+([A-Za-z_]\w*)",
)


def top_level_types(text):
    names, depth = [], 0
    for line in text.splitlines():
        stripped = line.strip()
        if depth == 0 and not stripped.startswith("//"):
            m = DECL.match(stripped)
            if m and not stripped.startswith("class func") and not stripped.startswith("class var"):
                names.append(m.group(2))
        # crude brace depth that ignores braces in strings and comments
        code = re.sub(r'"(?:\\.|[^"\\])*"', '""', line.split("//")[0])
        depth += code.count("{") - code.count("}")
        depth = max(depth, 0)
    seen = []
    for n in names:
        if n not in seen:
            seen.append(n)
    return seen


def source_text_readers(repo):
    blob = []
    for p in (repo / "Tests").rglob("*.swift"):
        try:
            blob.append(p.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            pass
    return "\n".join(blob)


def main(argv):
    repo = Path(argv[1]).resolve()
    min_lines = 800
    if "--min-lines" in argv:
        min_lines = int(argv[argv.index("--min-lines") + 1])
    tests = source_text_readers(repo)
    rows = []
    for p in sorted((repo / "Sources").rglob("*.swift")):
        text = p.read_text(encoding="utf-8", errors="replace")
        lines = text.count("\n") + 1
        if lines <= min_lines:
            continue
        types = top_level_types(text)
        if len(types) < 2:
            continue
        rel = p.relative_to(repo).as_posix()
        quoted = [f'"{rel}"', f'"{p.name}"', f'/{p.name}"', f'"{p.stem}"']
        status = "SKIP-source-text" if any(q in tests for q in quoted) else "MOVE"
        rows.append((status, lines, len(types), rel, ",".join(types)))
    for r in rows:
        print("\t".join(str(x) for x in r))
    move = sum(1 for r in rows if r[0] == "MOVE")
    print(f"# {len(rows)} multi-type files over {min_lines} lines, {move} movable, {len(rows) - move} read as source text", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
