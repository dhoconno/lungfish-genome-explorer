#!/usr/bin/env python3
"""How many lines a type-per-file move would take out of each file (finding R6).

Usage: type_spans.py <repo> <census.tsv>

For each MOVE row of a type_census.py TSV, finds the line span of every
top-level declaration (type or extension, with its leading doc comments and
attributes), picks the primary type (the one named like the file, else the
largest), and prints: path, total lines, lines that would move, lines left,
and the secondary types with their spans. Spans use the same crude brace
counter as type_census.py.
"""
import re
import sys
from pathlib import Path

DECL = re.compile(
    r"^(?:@[\w().:, ]+\s+)*(?:(?:public|internal|fileprivate|private|open|final|indirect|nonisolated)\s+)*"
    r"(class|struct|enum|protocol|actor|extension)\s+([A-Za-z_][\w.]*)",
)


def spans(text):
    lines = text.splitlines()
    out, depth, i = [], 0, 0
    while i < len(lines):
        s = lines[i].strip()
        m = DECL.match(s) if depth == 0 else None
        if m and not s.startswith(("class func", "class var")):
            start = i
            j = i - 1
            while j >= 0 and (lines[j].strip().startswith(("///", "//", "@", "/*", "*")) and lines[j].strip()):
                j -= 1
            start = j + 1
            d, k, opened = 0, i, False
            while k < len(lines):
                code = re.sub(r'"(?:\\.|[^"\\])*"', '""', lines[k].split("//")[0])
                d += code.count("{") - code.count("}")
                if "{" in code:
                    opened = True
                if opened and d <= 0:
                    break
                k += 1
            name = m.group(2).split(".")[0]
            out.append((m.group(1), name, start, k, k - start + 1))
            i = k + 1
            continue
        code = re.sub(r'"(?:\\.|[^"\\])*"', '""', lines[i].split("//")[0])
        depth = max(depth + code.count("{") - code.count("}"), 0)
        i += 1
    return out


def main(argv):
    repo, tsv = Path(argv[1]), Path(argv[2])
    for row in tsv.read_text().splitlines():
        cols = row.split("\t")
        if cols[0] != "MOVE":
            continue
        path = cols[3]
        text = (repo / path).read_text(encoding="utf-8", errors="replace")
        total = text.count("\n") + 1
        sp = spans(text)
        by_type = {}
        for kind, name, s, e, n in sp:
            by_type.setdefault(name, 0)
            by_type[name] += n
        stem = Path(path).stem
        primary = stem if stem in by_type else max(by_type, key=by_type.get)
        movable = sum(n for t, n in by_type.items() if t != primary)
        others = ",".join(f"{t}:{n}" for t, n in sorted(by_type.items(), key=lambda x: -x[1]) if t != primary)
        print(f"{path}\t{total}\t{movable}\t{total - movable}\t{primary}\t{others}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
