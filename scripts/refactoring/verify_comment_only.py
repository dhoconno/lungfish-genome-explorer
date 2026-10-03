#!/usr/bin/env python3
"""Verify that a git range changes only comments (and Python docstrings).

Usage: verify_comment_only.py <repo> <base> <head>

For every file modified between base and head:
- Swift: strips // and nested /* */ comments outside string literals
  (plain, multi-line and raw strings), then compares the remaining code
  line by line, ignoring blank lines and trailing whitespace.
- Python (by extension or a python shebang, including .sh-named
  ratchets): compares ast.dump of both versions with docstrings removed.
- Shell: strips unquoted # comments, then compares as for Swift.
- Anything else, and added, deleted or renamed files: reported as
  NEEDS-HUMAN for the reviewer to read.

Exit 0 when every modified file is comment-only, 1 otherwise. Prints one
line per file: OK, CODE-CHANGED (with the first differing line) or
NEEDS-HUMAN.
"""
import ast
import subprocess
import sys


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True,
                          capture_output=True, text=True).stdout


def show(repo, rev, path):
    try:
        return git(repo, "show", f"{rev}:{path}")
    except subprocess.CalledProcessError:
        return None


def strip_swift(src):
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif src.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    if src[i] == "\n":
                        out.append("\n")
                    i += 1
            continue
        # raw string: one or more # then "
        if c == "#":
            k = i
            while k < n and src[k] == "#":
                k += 1
            if k < n and src[k] == '"':
                hashes = src[i:k]
                multi = src.startswith('"""', k)
                quote = '"""' if multi else '"'
                end = quote + hashes
                j = src.find(end, k + len(quote))
                j = n if j < 0 else j + len(end)
                out.append(src[i:j])
                i = j
                continue
        if c == '"':
            multi = src.startswith('"""', i)
            quote = '"""' if multi else '"'
            j = i + len(quote)
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src.startswith(quote, j):
                    j += len(quote)
                    break
                if not multi and src[j] == "\n":
                    break
                j += 1
            out.append(src[i:j])
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def strip_shell(src):
    lines = []
    for line in src.splitlines():
        res, quote = [], None
        for idx, ch in enumerate(line):
            if quote:
                res.append(ch)
                if ch == quote:
                    quote = None
                continue
            if ch in ("'", '"'):
                quote = ch
                res.append(ch)
                continue
            if ch == "#" and (idx == 0 or line[idx - 1].isspace()):
                break
            res.append(ch)
        lines.append("".join(res))
    return "\n".join(lines)


def norm_lines(code):
    return [l.rstrip() for l in code.splitlines() if l.strip()]


def py_dump(src):
    tree = ast.parse(src)
    for node in ast.walk(tree):
        body = getattr(node, "body", None)
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                             ast.AsyncFunctionDef)) and body:
            first = body[0]
            if (isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant)
                    and isinstance(first.value.value, str)):
                node.body = body[1:] or [ast.Pass()]
    return ast.dump(tree, include_attributes=False)


def is_python(path, text):
    return path.endswith(".py") or (text or "").startswith("#!/usr/bin/env python")


def is_shell(path, text):
    first = (text or "").split("\n", 1)[0]
    return path.endswith((".sh", ".bash", ".zsh")) or first.startswith("#!") and "sh" in first


def main(argv):
    repo, base, head = argv[1:4]
    status = git(repo, "diff", "--name-status", "-M", f"{base}..{head}")
    ok = True
    for row in status.splitlines():
        parts = row.split("\t")
        kind, path = parts[0], parts[-1]
        if kind != "M":
            print(f"NEEDS-HUMAN {kind} {path}")
            ok = False
            continue
        old, new = show(repo, base, path), show(repo, head, path)
        try:
            if path.endswith(".swift"):
                a, b = norm_lines(strip_swift(old)), norm_lines(strip_swift(new))
            elif is_python(path, old):
                a, b = [py_dump(old)], [py_dump(new)]
            elif is_shell(path, old):
                a, b = norm_lines(strip_shell(old)), norm_lines(strip_shell(new))
            else:
                print(f"NEEDS-HUMAN unsupported-type {path}")
                ok = False
                continue
        except SyntaxError as exc:
            print(f"NEEDS-HUMAN parse-error {path}: {exc}")
            ok = False
            continue
        if a == b:
            print(f"OK {path}")
            continue
        ok = False
        first = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
        before = a[first] if first < len(a) else "<eof>"
        after = b[first] if first < len(b) else "<eof>"
        print(f"CODE-CHANGED {path}\n    - {before[:200]}\n    + {after[:200]}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
