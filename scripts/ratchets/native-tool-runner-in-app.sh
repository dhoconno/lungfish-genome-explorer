#!/usr/bin/env python3
"""native-tool-runner-in-app.sh - Ratchet on App files that name NativeToolRunner.

Counts, over Sources/LungfishApp/**/*.swift:
    files_naming_native_tool_runner   files that name NativeToolRunner outside a comment
The GUI runs the lungfish-cli command for an operation and the logic both paths share lives in
LungfishWorkflow (docs/contracts/RUNNING-A-TOOL.md), so an App file that names NativeToolRunner
still drives a managed tool in process. The count may only fall.
The count is of files, so a second mention in a counted file changes nothing. Text in // and
/* */ comments is ignored, doc comments included, and Swift block comments nest. A string
literal is read only to find its end, so a // inside a URL does not start a comment. Only the
whole identifier counts, so NativeToolRunnerError does not.

Baseline file: one "<name> <count>" line per count.

Usage:
    scripts/ratchets/native-tool-runner-in-app.sh              # check against the recorded baseline
    scripts/ratchets/native-tool-runner-in-app.sh --print      # print each occurrence and the count, no pass/fail
    scripts/ratchets/native-tool-runner-in-app.sh --update     # rewrite the baseline to the current count
                                                                 (only for a deliberate, reviewed increase)

Exit codes: 0 = the count is at or under baseline, 1 = the count rose.
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
APP_DIR = REPO_ROOT / "Sources" / "LungfishApp"
BASELINE_FILE = Path(__file__).resolve().with_suffix(".baseline")

NAME_RX = re.compile(r"(?<!\w)NativeToolRunner(?!\w)")

NAMES = ("files_naming_native_tool_runner",)

HEADER = (
    "# native-tool-runner-in-app baseline: Swift files under Sources/LungfishApp that name "
    "NativeToolRunner outside comments. The count may only fall."
)


def block_comment_end(text, i):
    """Index just past the /* */ comment that opens at text[i]. Swift block comments nest."""
    depth = 0
    n = len(text)
    while i < n:
        if text.startswith("/*", i):
            depth += 1
            i += 2
        elif text.startswith("*/", i):
            depth -= 1
            i += 2
            if depth == 0:
                return i
        else:
            i += 1
    return n


def skip_interpolation(text, i):
    """Index just past the ')' that closes a string interpolation whose '(' ends just before text[i]."""
    depth = 1
    n = len(text)
    while i < n and depth:
        if text[i] == '"':
            i = skip_string(text, i)
            continue
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
        i += 1
    return i


def skip_string(text, i):
    """Index just past the string literal whose opening quote is at text[i].

    Handles "..." (which ends at a line break), triple-quoted strings, raw strings such as
    #"..."# and \\( ... ) interpolation, whose contents can hold quotes and parentheses.
    """
    pounds = ""
    j = i
    while j > 0 and text[j - 1] == "#":
        pounds += "#"
        j -= 1
    quote = '"""' if text.startswith('"""', i) else '"'
    end = quote + pounds
    escape = "\\" + pounds
    n = len(text)
    i += len(quote)
    while i < n:
        if text.startswith(escape + "(", i):
            i = skip_interpolation(text, i + len(escape) + 1)
        elif text.startswith(escape, i):
            i += len(escape) + 1
        elif text.startswith(end, i):
            return i + len(end)
        elif quote == '"' and text[i] == "\n":
            return i
        else:
            i += 1
    return n


def strip_comments(text):
    """Replace every comment in Swift source with spaces and keep every line break."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end == -1 else end
        elif text.startswith("/*", i):
            end = block_comment_end(text, i)
        elif text[i] == '"':
            end = skip_string(text, i)
            out.append(text[i:end])
            i = end
            continue
        else:
            out.append(text[i])
            i += 1
            continue
        out.append(re.sub(r"[^\n]", " ", text[i:end]))
        i = end
    return "".join(out)


def scan():
    counts = {name: 0 for name in NAMES}
    sites = []
    if not APP_DIR.is_dir():
        return counts, sites
    for path in sorted(APP_DIR.rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        if "NativeToolRunner" not in text:
            continue
        rel = path.relative_to(REPO_ROOT).as_posix()
        names_it = False
        for lineno, line in enumerate(strip_comments(text).split("\n"), 1):
            for _ in NAME_RX.finditer(line):
                names_it = True
                sites.append(f"{rel}:{lineno}: NativeToolRunner")
        if names_it:
            counts["files_naming_native_tool_runner"] += 1
    return counts, sites


def read_baseline():
    if not BASELINE_FILE.exists():
        return None
    entries = {}
    for line in BASELINE_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, _, num = line.rpartition(" ")
        try:
            entries[name] = int(num)
        except ValueError:
            continue
    return entries


def main(argv):
    counts, sites = scan()

    if "--print" in argv:
        for s in sites:
            print(s)
        for name, n in counts.items():
            print(f"TOTAL {name} {n}")
        return 0

    if "--update" in argv:
        lines = [HEADER]
        lines += [f"{name} {n}" for name, n in counts.items()]
        BASELINE_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("Updated baseline: " + ", ".join(f"{n} {name}" for name, n in counts.items()) + ".")
        return 0

    baseline = read_baseline()
    if baseline is None:
        print(
            f"native-tool-runner-in-app: no baseline recorded at {BASELINE_FILE}. "
            f"Run with --update to record the current counts.",
            file=sys.stderr,
        )
        return 1

    over = [(name, n, baseline.get(name, 0)) for name, n in counts.items() if n > baseline.get(name, 0)]
    if over:
        for name, n, base in over:
            print(
                f"native-tool-runner-in-app: {n} for {name}, up from the recorded baseline of {base}.",
                file=sys.stderr,
            )
        print(
            "An App file should not name NativeToolRunner. A GUI operation runs its lungfish-cli "
            "command, and the logic both paths share lives in LungfishWorkflow "
            "(docs/contracts/RUNNING-A-TOOL.md). Run with --print to list the sites.",
            file=sys.stderr,
        )
        return 1

    lower = [name for name, n in counts.items() if n < baseline.get(name, 0)]
    summary = ", ".join(f"{n} {name}" for name, n in counts.items())
    if lower:
        print(
            f"native-tool-runner-in-app: {summary}. Down from baseline for {', '.join(lower)}. "
            f"Run with --update to lower the baseline."
        )
    else:
        print(f"native-tool-runner-in-app: {summary}, at the recorded baseline.")
    return 0


if __name__ == "__main__":
    import ratchet_baseline
    sys.exit(ratchet_baseline.run(main, sys.argv[1:], BASELINE_FILE))
