#!/usr/bin/env python3
"""Check a golden recapture against the predictions written before it.

    python3 scripts/golden/predictions.py check PREDICTIONS.json [--old SPEC] [--new SPEC] [-v]
    python3 scripts/golden/predictions.py diff [--old SPEC] [--new SPEC] [-v]

A lane that recaptures goldens writes its predictions first, runs
`golden.py capture`, then runs `check`. The command compares two copies of the
goldens and exits 1 when a change was not predicted, when a changed value
differs from its prediction or when a prediction did not happen. Whatever the
result, a PREDICTED table lists the number of changes each prediction
accepted and, under each filesAdded or filesRemoved entry, the names of the
files it accepted. `-v` lists every change one by one. `diff` prints the
observed changes with no predictions. Exit status 2 means the predictions
file, a SPEC or git could not be used.

A SPEC names one copy of Tests/Fixtures/golden (see --root). It is a git
revision (--old defaults to HEAD), WORKTREE (--new defaults to it) or
dir:PATH, a folder that holds the goldens themselves. Two commits are
`--old HEAD~1 --new HEAD`.

Predictions file, one JSON object:

    {
      "version": 1,
      "ignore": {"README.md": "documentation, not captured data"},
      "files": [
        {
          "file": ["genotype/bundle/provenance/*.json", "genotype/exports/*.json"],
          "why": "steps record the version of the environment that ran",
          "changed": [{"path": "/steps[*]/toolVersion", "old": "unknown", "pattern": "[0-9][0-9.]*"}],
          "added": [{"path": "/steps[*]/toolVersionEvidence"}],
          "removed": [{"path": "/steps[*]/processIdentifier", "count": 26}]
        },
        {
          "file": "cli-help/lungfish-cli.map.txt",
          "why": "the new option",
          "added": [{"value": "  --max-secondary <n>  Maximum secondary alignments."}]
        }
      ],
      "filesAdded": {"cli-help/lungfish-cli.new.txt": "the new command"},
      "filesRemoved": {}
    }

- "file" in "files" and the keys of "filesAdded", "filesRemoved" and "ignore"
  are paths below the golden root or globs. `*` and `?` stay inside a folder
  and `**` crosses folders. "file" may be a list. An entry in "files" needs a
  "why", and the value of each key in the other three is the reason. In
  "filesAdded" and "filesRemoved" it may be {"why": "...", "count": 2} for a
  glob that must match exactly two files. A change to a file that no entry or
  ignore names is unpredicted, so a scientific payload nobody listed has to
  stay byte for byte the same. An ignore leaves a file out of the comparison,
  and the report lists each ignored file whose bytes differ.
- A ".json" file is compared as JSON. A path is JSON pointer style with the
  array index in brackets, `/steps[3]/argv[0]`. `[*]` is any index, `*` any
  object key and `~1` a slash inside a key. An index names the position in
  the new file for changed and added values and in the old file for removed
  ones. A rule with no path names the document itself. Numbers compare by
  their spelling, like the bytes do.
- Every other file is compared by line and its rules have no path. A line that
  changes in place is `changed`, one that appears is `added` and one that goes
  is `removed`, and a report counts lines from 1 in the new file (the old file
  for a removed line). A file that is not UTF-8 text can only be predicted as
  `binary: true`.
- `reordered` is the same elements, lines or object keys in another order.
  Goldens are compared byte for byte, so order is part of the content.
- `reformatted: true` is the same JSON value in other bytes, such as a new
  final newline, line ending, indentation, colon spacing or escaping.
- A rule may add `old` or `oldPattern` for the value before the change (not on
  `added`) and `value` or `pattern` for the value after it (not on `removed`).
  A pattern is a regular expression that must match the whole value, where a
  number, true, false and null match by their text. `count` is the exact
  number of changes a rule must account for. Without it one change is enough.
  A rule may carry its own "why".
- A change at a place a rule names with a value the rule does not allow is a
  wrong value, and the rule counts as used, so it is not also unfulfilled.
  When several rules cover one change, the rules that give an `old`,
  `oldPattern`, `value` or `pattern` decide. A change that all of them refuse
  is a wrong value even when a rule without one covers it too, and then no
  rule counts it.
"""

from __future__ import annotations

import argparse
import difflib
import functools
import hashlib
import json
import re
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]
DEFAULT_ROOT = "Tests/Fixtures/golden"
MAX_TEXT_LINES_PER_KIND = 10
DISPLAY_LIMIT = 72


class SpecError(Exception):
    """Something the checker cannot use, such as a predictions file or a revision."""


class _Marker:
    def __init__(self, text: str) -> None:
        self.text = text

    def __repr__(self) -> str:
        return self.text


ANY_INDEX = _Marker("[*]")
ANY_KEY = _Marker("/*")
MISSING = _Marker("(none)")

# ---------------------------------------------------------------------------
# JSON that keeps numbers as they are spelled


class Num:
    """A JSON number kept as its text, so 1 and 1.0 stay different, as their bytes do."""

    __slots__ = ("text",)

    def __init__(self, text: str) -> None:
        self.text = text


def parse_json(text: str) -> Any:
    return json.loads(text, parse_int=Num, parse_float=Num, parse_constant=Num)


def dump(node: Any) -> str:
    """Compact text with object keys in file order, so equal dumps mean equal content and order.

    Strings are quoted and numbers are not, so the number 1 and the string "1" differ."""
    if isinstance(node, dict):
        return "{" + ",".join(f"{json.dumps(k, ensure_ascii=False)}:{dump(v)}" for k, v in node.items()) + "}"
    if isinstance(node, list):
        return "[" + ",".join(dump(v) for v in node) + "]"
    if isinstance(node, Num):
        return node.text
    return json.dumps(node, ensure_ascii=False)


def display(node: Any) -> str:
    if node is MISSING:
        return MISSING.text
    text = dump(node)
    return text if len(text) <= DISPLAY_LIMIT else text[: DISPLAY_LIMIT - 3] + "..."


# ---------------------------------------------------------------------------
# Paths and globs

_PATH_TOKEN = re.compile(r"/((?:[^/\[\]~]|~[01])*)|\[(\d+|\*)\]")


def parse_path(text: str) -> tuple:
    """`/steps[*]/argv[0]` becomes ("steps", ANY_INDEX, "argv", 0)."""
    segments: list = []
    position = 0
    while position < len(text):
        token = _PATH_TOKEN.match(text, position)
        if not token:
            raise ValueError(f"cannot read the path {text!r} at offset {position}")
        position = token.end()
        if token.group(2) is not None:
            segments.append(ANY_INDEX if token.group(2) == "*" else int(token.group(2)))
        elif token.group(1) == "" and text.startswith("[", position):
            continue  # "/[*]" means "[*]"
        else:
            key = token.group(1)
            segments.append(ANY_KEY if key == "*" else key.replace("~1", "/").replace("~0", "~"))
    return tuple(segments)


def render_path(path: tuple) -> str:
    parts = []
    for segment in path:
        if isinstance(segment, _Marker):
            parts.append(segment.text)
        elif isinstance(segment, int):
            parts.append(f"[{segment}]")
        else:
            parts.append("/" + segment.replace("~", "~0").replace("/", "~1"))
    return "".join(parts)


def path_matches(pattern: tuple, path: tuple) -> bool:
    def one(expected: Any, actual: Any) -> bool:
        if expected is ANY_INDEX:
            return isinstance(actual, int)
        if expected is ANY_KEY:
            return isinstance(actual, str)
        return type(expected) is type(actual) and expected == actual

    return len(pattern) == len(path) and all(one(e, a) for e, a in zip(pattern, path))


@functools.lru_cache(maxsize=None)
def glob_regex(glob: str) -> re.Pattern:
    out, i = [], 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif glob[i] == "*":
            out.append("[^/]*")
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    return re.compile("".join(out))


# ---------------------------------------------------------------------------
# Trees


def read_directory(directory: Path) -> dict[str, bytes]:
    if not directory.is_dir():
        raise SpecError(f"{directory} is not a folder")
    return {
        path.relative_to(directory).as_posix(): path.read_bytes()
        for path in sorted(directory.rglob("*"))
        if path.is_file()
    }


def _git(repo: Path, *args: str, stdin: bytes | None = None) -> bytes:
    done = subprocess.run(["git", "-C", str(repo), *args], input=stdin, capture_output=True)
    if done.returncode != 0:
        message = done.stderr.decode("utf-8", "replace").strip() or "no message"
        raise SpecError(f"git {args[0]} failed in {repo}: {message}")
    return done.stdout


def read_git_tree(repo: Path, commit: str, root: str) -> dict[str, bytes]:
    listing = _git(repo, "ls-tree", "-r", "-z", f"{commit}:{root}")
    names, shas = [], []
    for record in listing.split(b"\0"):
        meta, _, name = record.partition(b"\t")
        fields = meta.decode().split()
        if len(fields) == 3 and fields[1] == "blob":
            names.append(name.decode("utf-8", "replace"))
            shas.append(fields[2])
    blobs = _git(repo, "cat-file", "--batch", stdin="".join(sha + "\n" for sha in shas).encode())
    files, position = {}, 0
    for name in names:
        end = blobs.index(b"\n", position)
        header = blobs[position:end].split()
        if len(header) != 3:
            raise SpecError(f"git could not read {commit}:{root}/{name}")
        size = int(header[2])
        files[name] = blobs[end + 1 : end + 1 + size]
        position = end + 1 + size + 1
    return files


def load_tree(spec: str, root: str, repo: Path) -> tuple[str, dict[str, bytes]]:
    if spec == "WORKTREE":
        return f"working tree {root}", read_directory(repo / root)
    if spec.startswith("dir:"):
        return spec, read_directory(Path(spec[4:]).expanduser())
    if spec.startswith("-"):
        raise SpecError(f"{spec!r} is not a revision")
    try:
        commit = _git(repo, "rev-parse", "--verify", "--quiet", f"{spec}^{{commit}}").decode().strip()
    except SpecError:
        raise SpecError(f"{spec!r} is not WORKTREE, dir:PATH or a revision of {repo}") from None
    return f"{spec} ({commit[:9]})", read_git_tree(repo, commit, root)


# ---------------------------------------------------------------------------
# Observed changes


@dataclass(frozen=True)
class Change:
    file: str
    kind: str  # file-added, file-removed, binary, invalid-json, reformatted, reordered, changed, added, removed
    path: tuple | None = None  # a JSON path, () for the document itself, None for text lines and whole files
    old: Any = MISSING
    new: Any = MISSING
    line: int | None = None
    note: str = ""


KIND_ORDER = ("file-added", "file-removed", "invalid-json", "binary", "reformatted", "reordered", "removed", "changed", "added")
WHOLE_FILE_KINDS = ("file-added", "file-removed")


def as_text(data: bytes) -> str | None:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None
    return None if "\0" in text else text


def walk_json(file: str, old: Any, new: Any, path: tuple, out: list[Change]) -> None:
    if isinstance(old, dict) and isinstance(new, dict):
        for key in old:
            if key not in new:
                out.append(Change(file, "removed", path + (key,), old=old[key]))
        for key in new:
            if key not in old:
                out.append(Change(file, "added", path + (key,), new=new[key]))
            else:
                walk_json(file, old[key], new[key], path + (key,), out)
        if [k for k in old if k in new] != [k for k in new if k in old]:
            out.append(Change(file, "reordered", path, note="object keys"))
    elif isinstance(old, list) and isinstance(new, list):
        walk_list(file, old, new, path, out)
    elif dump(old) != dump(new):
        out.append(Change(file, "changed", path, old=old, new=new))


def walk_list(file: str, old: list, new: list, path: tuple, out: list[Change]) -> None:
    before, after = [dump(x) for x in old], [dump(x) for x in new]
    if before == after:
        return
    if len(before) == len(after) and Counter(before) == Counter(after):
        out.append(Change(file, "reordered", path, note=f"{len(old)} elements"))
        return
    matcher = difflib.SequenceMatcher(None, before, after, autojunk=len(before) + len(after) > 5_000)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        paired = min(i2 - i1, j2 - j1)
        for k in range(paired):
            walk_json(file, old[i1 + k], new[j1 + k], path + (j1 + k,), out)
        out.extend(Change(file, "removed", path + (k,), old=old[k]) for k in range(i1 + paired, i2))
        out.extend(Change(file, "added", path + (k,), new=new[k]) for k in range(j1 + paired, j2))


_LITERAL = re.compile(r'"(?:[^"\\]|\\.)*"|-?\d[0-9.eE+\-]*')


def json_layout(text: str) -> dict[str, Any]:
    """How a JSON file is written, as traits a change of encoder would flip. None means the file shows no sign."""
    skeleton = _LITERAL.sub("0", text)
    indents = [len(m) for m in re.findall(r"^[ \t]+", text, re.M)]

    def seen(*found: tuple[str, bool]) -> str | None:
        return " and ".join(name for name, present in found if present) or None

    def spaces(pattern: str) -> str | None:
        return ", ".join(sorted({str(len(m)) for m in re.findall(pattern, skeleton)})) or None

    return {
        "final newline": text.endswith("\n"),
        "line endings": "CRLF" if "\r\n" in text else "LF",
        "indentation": min(indents) if indents else None,
        "spaces before colons": spaces(r"( *):"),
        "spaces after colons": spaces(r":( *)"),
        "spaces after commas": spaces(r",( *)(?=\S)"),
        "slashes": seen(("escaped", "\\/" in text), ("plain", "/" in text.replace("\\/", ""))),
        "non-ASCII characters": seen(
            ("escaped", bool(re.search(r"\\u[0-9a-fA-F]{4}", text))), ("plain", bool(re.search(r"[^\x00-\x7f]", text)))
        ),
        "empty containers": seen(
            ("blank line", bool(re.search(r"[\[{][ \t]*\n[ \t]*\n", skeleton))), ("compact", bool(re.search(r"\[\]|\{\}", skeleton)))
        ),
    }


def compare_json(file: str, before: str, after: str) -> list[Change]:
    try:
        old, new = parse_json(before), parse_json(after)
    except ValueError as error:
        return [Change(file, "invalid-json", note=str(error))] + compare_text(file, before, after)
    out: list[Change] = []
    walk_json(file, old, new, (), out)
    a, b = json_layout(before), json_layout(after)
    differences = [f"{k} {a[k]} -> {b[k]}" for k in a if a[k] is not None and b[k] is not None and a[k] != b[k]]
    if differences:
        out.append(Change(file, "reformatted", note=", ".join(differences)))
    elif not out and before != after:
        lines = list(zip(before.split("\n"), after.split("\n")))
        first = next((n for n, (x, y) in enumerate(lines, 1) if x != y), len(lines) + 1)
        out.append(Change(file, "reformatted", line=first, note="the JSON value is equal and the bytes are not"))
    return out


def split_lines(text: str) -> tuple[list[str], bool]:
    if text == "":
        return [], True
    lines = text.split("\n")
    final_newline = text.endswith("\n")
    if final_newline:
        lines.pop()
    return lines, final_newline


def compare_text(file: str, before: str, after: str) -> list[Change]:
    old, old_final = split_lines(before)
    new, new_final = split_lines(after)
    out: list[Change] = []
    if old != new:
        if len(old) == len(new) and Counter(old) == Counter(new):
            out.append(Change(file, "reordered", note=f"{len(old)} lines"))
        else:
            matcher = difflib.SequenceMatcher(None, old, new, autojunk=len(old) + len(new) > 50_000)
            for tag, i1, i2, j1, j2 in matcher.get_opcodes():
                if tag == "equal":
                    continue
                paired = min(i2 - i1, j2 - j1)
                out.extend(Change(file, "changed", old=old[i1 + k], new=new[j1 + k], line=j1 + k + 1) for k in range(paired))
                out.extend(Change(file, "removed", old=old[k], line=k + 1) for k in range(i1 + paired, i2))
                out.extend(Change(file, "added", new=new[k], line=k + 1) for k in range(j1 + paired, j2))
    if old_final != new_final:
        out.append(Change(file, "reformatted", note="the final newline " + ("was added" if new_final else "was removed")))
    return out


def describe_bytes(data: bytes) -> str:
    return f"{len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()[:12]}"


def compare_trees(old: dict[str, bytes], new: dict[str, bytes]) -> list[Change]:
    changes: list[Change] = []
    for name in sorted(old.keys() | new.keys()):
        before, after = old.get(name), new.get(name)
        if before == after:
            continue
        if before is None:
            changes.append(Change(name, "file-added"))
        elif after is None:
            changes.append(Change(name, "file-removed"))
        else:
            text_before, text_after = as_text(before), as_text(after)
            if text_before is None or text_after is None:
                changes.append(Change(name, "binary", old=describe_bytes(before), new=describe_bytes(after)))
            elif name.endswith(".json"):
                changes.extend(compare_json(name, text_before, text_after))
            else:
                changes.extend(compare_text(name, text_before, text_after))
    return changes


# ---------------------------------------------------------------------------
# Predictions

RULE_KEYS = {
    "changed": {"path", "old", "oldPattern", "value", "pattern", "count", "why"},
    "added": {"path", "value", "pattern", "count", "why"},
    "removed": {"path", "old", "oldPattern", "count", "why"},
    "reordered": {"path", "count", "why"},
}
FLAG_KINDS = ("reformatted", "binary")
TOP_KEYS = {"version", "why", "ignore", "files", "filesAdded", "filesRemoved"}


@dataclass(frozen=True, eq=False)
class Rule:
    globs: tuple[str, ...]
    kind: str
    why: str
    path: tuple | None = None
    old: Any = MISSING
    old_pattern: re.Pattern | None = None
    value: Any = MISSING
    pattern: re.Pattern | None = None
    count: int | None = None

    def covers(self, change: Change) -> bool:
        if self.kind != change.kind or not any(glob_regex(g).fullmatch(change.file) for g in self.globs):
            return False
        if self.path is None:
            return not change.path
        return change.path is not None and path_matches(self.path, change.path)

    def value_problem(self, change: Change) -> str | None:
        for label, exact, pattern, seen in (
            ("old value", self.old, self.old_pattern, change.old),
            ("new value", self.value, self.pattern, change.new),
        ):
            if exact is not MISSING and dump(exact) != dump(seen):
                return f"{label} is {display(seen)}, predicted {display(exact)}"
            if pattern is not None and not scalar_matches(pattern, seen):
                return f"{label} {display(seen)} does not match /{pattern.pattern}/"
        return None

    def decides(self) -> bool:
        """Whether the rule gives a value or a pattern, so that it can refuse a change it covers."""
        return self.old is not MISSING or self.value is not MISSING or self.old_pattern is not None or self.pattern is not None

    def label(self) -> str:
        files = " | ".join(self.globs[:2]) + (f" (+{len(self.globs) - 2} more)" if len(self.globs) > 2 else "")
        parts = [files, self.kind]
        if self.path is not None:
            parts.append(render_path(self.path) or "(document)")
        for name, shown in (("old", self.old), ("value", self.value)):
            if shown is not MISSING:
                parts.append(f"{name} {display(shown)}")
        for name, shown in (("oldPattern", self.old_pattern), ("pattern", self.pattern)):
            if shown is not None:
                parts.append(f"{name} /{shown.pattern}/")
        return "  ".join(parts)


@dataclass
class Predictions:
    rules: list[Rule]
    ignore: list[tuple[re.Pattern, str]]  # the pattern of each ignore glob and the reason given for it


def scalar_matches(pattern: re.Pattern, node: Any) -> bool:
    if isinstance(node, (dict, list)) or node is MISSING:
        return False
    text = node if isinstance(node, str) else node.text if isinstance(node, Num) else dump(node)
    return pattern.fullmatch(text) is not None


def load_predictions(text: str) -> Predictions:
    problems: list[str] = []

    def bad(where: str, message: str) -> None:
        problems.append(f"{where}: {message}")

    def mapping(node: Any, where: str) -> dict:
        if node is not None and not isinstance(node, dict):
            bad(where, "must be an object")
        return node if isinstance(node, dict) else {}

    def count_of(spec: dict, where: str) -> int | None:
        node = spec.get("count")
        if node is not None and not (isinstance(node, Num) and re.fullmatch(r"[1-9][0-9]*", node.text)):
            bad(where, "count must be a whole number of at least 1")
            return None
        return int(node.text) if node is not None else None

    def pattern_of(spec: dict, key: str, where: str) -> re.Pattern | None:
        if key not in spec:
            return None
        try:
            if isinstance(spec[key], str):
                return re.compile(spec[key])
            bad(where, f"{key} must be a regular expression string")
        except re.error as error:
            bad(where, f"{key} is not a regular expression: {error}")
        return None

    def globs_of(node: Any, where: str) -> tuple[str, ...]:
        items = [node] if isinstance(node, str) else node
        if not isinstance(items, list) or not items or not all(isinstance(g, str) and g for g in items):
            bad(where, "file must be a path or glob, or a list of them")
            return ()
        return tuple(items)

    def make_rule(globs: tuple[str, ...], kind: str, spec: Any, entry_why: str, where: str) -> Rule | None:
        if not isinstance(spec, dict):
            bad(where, "must be an object")
            return None
        for key in sorted(spec.keys() - RULE_KEYS[kind]):
            bad(where, f"{key!r} does not belong in a rule under {kind}")
        path = None
        if "path" in spec:
            try:
                path = parse_path(spec["path"]) if isinstance(spec["path"], str) else bad(where, "path must be a string")
            except ValueError as error:
                bad(where, str(error))
        why = spec["why"] if isinstance(spec.get("why"), str) and spec["why"].strip() else entry_why
        return Rule(
            globs, kind, why, path, spec.get("old", MISSING), pattern_of(spec, "oldPattern", where),
            spec.get("value", MISSING), pattern_of(spec, "pattern", where), count_of(spec, where),
        )

    try:
        doc = parse_json(text)
    except ValueError as error:
        raise SpecError(f"the predictions file is not JSON: {error}") from None
    if not isinstance(doc, dict):
        raise SpecError("the predictions file must hold one JSON object")
    for key in sorted(doc.keys() - TOP_KEYS):
        bad(key, "unknown top-level key")
    version = doc.get("version", Num("1"))
    if not (isinstance(version, Num) and version.text == "1"):
        bad("version", "must be 1")

    rules: list[Rule] = []
    entries = doc.get("files", [])
    if not isinstance(entries, list):
        bad("files", "must be a list of entries")
        entries = []
    for number, entry in enumerate(entries):
        where = f"files[{number}]"
        if not isinstance(entry, dict):
            bad(where, "must be an object")
            continue
        globs = globs_of(entry.get("file"), where)
        why = entry.get("why") if isinstance(entry.get("why"), str) else ""
        if not why.strip():
            bad(where, "needs a non-empty why")
        if not any(key in RULE_KEYS or key in FLAG_KINDS for key in entry):
            bad(where, "predicts nothing, add changed, added, removed, reordered, reformatted or binary")
        for key, value in entry.items():
            if key in RULE_KEYS and isinstance(value, list):
                made = (make_rule(globs, key, item, why, f"{where}.{key}[{n}]") for n, item in enumerate(value))
                rules.extend(rule for rule in made if rule is not None)
            elif key in RULE_KEYS:
                bad(f"{where}.{key}", "must be a list of rules")
            elif key in FLAG_KINDS:
                if value is True:
                    rules.append(Rule(globs, key, why))
                else:
                    bad(f"{where}.{key}", "must be true")
            elif key not in ("file", "why"):
                bad(where, f"unknown key {key!r}")
    for key, kind in (("filesAdded", "file-added"), ("filesRemoved", "file-removed")):
        for glob, spec in mapping(doc.get(key), key).items():
            where = f"{key}[{glob!r}]"
            body = {"why": spec} if isinstance(spec, str) else spec
            if not isinstance(body, dict) or not isinstance(body.get("why"), str) or not body["why"].strip():
                bad(where, "needs a non-empty why, as a string or as an object with why and count")
                continue
            for extra in sorted(body.keys() - {"why", "count"}):
                bad(where, f"unknown key {extra!r}")
            rules.append(Rule((glob,), kind, body["why"], count=count_of(body, where)))
    ignore = []
    for glob, why in mapping(doc.get("ignore"), "ignore").items():
        if not isinstance(why, str) or not why.strip():
            bad(f"ignore[{glob!r}]", "needs a non-empty why")
        ignore.append((glob_regex(glob), why if isinstance(why, str) else ""))
    if problems:
        raise SpecError("the predictions file has problems\n" + "\n".join(f"  {p}" for p in problems))
    return Predictions(rules, ignore)


# ---------------------------------------------------------------------------
# Checking


@dataclass
class Verdict:
    unpredicted: list[Change]
    wrong: list[tuple[Change, Rule, str]]
    unfulfilled: list[tuple[Rule, int]]
    accepted: list[int]  # per rule, in rule order
    accepted_files: list[list[str]]  # per rule, the files that a file-added or file-removed rule accepted

    @property
    def ok(self) -> bool:
        return not (self.unpredicted or self.wrong or self.unfulfilled)


def evaluate(changes: list[Change], rules: list[Rule]) -> Verdict:
    accepted, touched = [0] * len(rules), [False] * len(rules)
    accepted_files: list[list[str]] = [[] for _ in rules]
    unpredicted, wrong = [], []
    for change in changes:
        covering = [n for n, rule in enumerate(rules) if rule.covers(change)]
        if not covering:
            unpredicted.append(change)
            continue
        problems = {n: rules[n].value_problem(change) for n in covering}
        # The covering rules that give a value or a pattern decide, and when none does they all do.
        deciders = [n for n in covering if rules[n].decides()] or covering
        if any(problems[n] is None for n in deciders):
            for n in covering:
                if problems[n] is None:
                    accepted[n] += 1
                    if change.kind in WHOLE_FILE_KINDS:
                        accepted_files[n].append(change.file)
        else:
            wrong.append((change, rules[deciders[0]], problems[deciders[0]]))
            for n in covering:
                touched[n] = True
    unfulfilled = [
        (rule, accepted[n])
        for n, rule in enumerate(rules)
        if (accepted[n] != rule.count if rule.count is not None else not (accepted[n] or touched[n]))
    ]
    return Verdict(unpredicted, wrong, unfulfilled, accepted, accepted_files)


def where(change: Change) -> str:
    if change.path is not None:
        return render_path(change.path) or "(document)"
    return f"line {change.line}" if change.line else ""


def values(change: Change) -> str:
    return {
        "changed": f"{display(change.old)} -> {display(change.new)}",
        "added": display(change.new),
        "removed": display(change.old),
        "binary": f"{change.old} -> {change.new}",
    }.get(change.kind, change.note)


def describe(change: Change) -> str:
    return " ".join(part for part in (change.kind, where(change), values(change)) if part)


def group_lines(changes: list[Change], verbose: bool) -> list[str]:
    """JSON changes group by file, kind and path with indexes as [*]. Text and whole-file changes list one by one."""
    groups: dict[tuple, list[Change]] = {}
    for change in sorted(changes, key=lambda c: (c.file, KIND_ORDER.index(c.kind), render_path(c.path or ()), c.line or 0)):
        pattern = render_path(tuple(ANY_INDEX if isinstance(s, int) else s for s in change.path)) if change.path else None
        groups.setdefault((change.file, change.kind, pattern), []).append(change)
    lines = []
    for (file, kind, pattern), members in groups.items():
        if pattern is not None and len(members) > 1 and not verbose:
            first = members[0]
            lines.append(f"  {file}  {kind} {pattern}  x{len(members)}, first {where(first)}: {values(first)}")
            continue
        shown = members if verbose or pattern is not None else members[:MAX_TEXT_LINES_PER_KIND]
        lines.extend(f"  {file}  {describe(change)}" for change in shown)
        if len(shown) < len(members):
            lines.append(f"  {file}  {kind}: {len(members) - len(shown)} more, -v lists them")
    return lines


def format_verdict(
    verdict: Verdict, rules: list[Rule], changes: list[Change], verbose: bool, ignored: list[tuple[str, str]] | None = None
) -> list[str]:
    ignored = ignored or []
    lines = []
    if ignored:
        lines.append(f"IGNORED ({len(ignored)} files)")
        lines += [f"  {name}  {why}" for name, why in ignored]
    if verdict.unpredicted:
        lines.append(f"UNPREDICTED, no prediction covers these ({len(verdict.unpredicted)} changes)")
        lines += group_lines(verdict.unpredicted, verbose)
    if verdict.wrong:
        lines.append(f"WRONG VALUE, the place was predicted and the value was not ({len(verdict.wrong)} changes)")
        groups: dict[tuple, tuple[Rule, str, list[Change]]] = {}
        for change, rule, problem in verdict.wrong:
            groups.setdefault((id(rule), problem), (rule, problem, []))[2].append(change)
        for rule, problem, members in groups.values():
            lines.append(f"  [{rule.label()}] {problem}")
            for change in members if verbose else members[:1]:
                lines.append(f"    {change.file}  {change.kind} {where(change)}")
            if len(members) > 1 and not verbose:
                lines.append(f"    and {len(members) - 1} more, -v lists them")
    if verdict.unfulfilled:
        lines.append(f"UNFULFILLED, these predictions did not happen ({len(verdict.unfulfilled)})")
        for rule, got in verdict.unfulfilled:
            need = f"expected exactly {rule.count}, accounted for {got}" if rule.count is not None else "no change matched"
            lines.append(f"  {rule.label()}  ({need})" + (f"  why: {rule.why}" if rule.why else ""))
    if rules:
        lines.append("PREDICTED")
        for n, rule in enumerate(rules):
            lines.append(f"  {verdict.accepted[n]:>6}  {rule.label()}")
            lines += [f"          {name}" for name in verdict.accepted_files[n]]
    lines.append(
        f"{'OK' if verdict.ok else 'FAILED'}: {len(changes)} changes in {len({c.file for c in changes})} files, "
        f"{len(verdict.unpredicted)} unpredicted, {len(verdict.wrong)} with a wrong value, "
        f"{len(verdict.unfulfilled)} of {len(rules)} predictions unfulfilled, {len(ignored)} ignored"
    )
    return lines


def drop_ignored(tree: dict[str, bytes], ignore: list[tuple[re.Pattern, str]]) -> dict[str, bytes]:
    return {name: data for name, data in tree.items() if not any(pattern.fullmatch(name) for pattern, _ in ignore)}


def ignored_differences(old: dict[str, bytes], new: dict[str, bytes], ignore: list[tuple[re.Pattern, str]]) -> list[tuple[str, str]]:
    """The files an ignore leaves out although their bytes differ between the trees, with the reason given for it."""
    found = []
    for name in sorted(old.keys() | new.keys()):
        if old.get(name) != new.get(name):
            reason = next((why for pattern, why in ignore if pattern.fullmatch(name)), None)
            if reason is not None:
                found.append((name, reason))
    return found


def run(args: argparse.Namespace) -> int:
    predictions = Predictions([], [])
    if args.command == "check":
        try:
            predictions = load_predictions(args.predictions.read_text(encoding="utf-8"))
        except OSError as error:
            raise SpecError(f"cannot read {args.predictions}: {error}") from None
    old_label, old = load_tree(args.old, args.root, args.repo)
    new_label, new = load_tree(args.new, args.root, args.repo)
    ignored = ignored_differences(old, new, predictions.ignore)
    old, new = drop_ignored(old, predictions.ignore), drop_ignored(new, predictions.ignore)
    changes = compare_trees(old, new)
    print(f"golden predictions: {old_label} -> {new_label}")
    print(f"{len(old)} files before, {len(new)} after, {len({c.file for c in changes})} with changes")
    if args.command == "diff":
        print("\n".join(group_lines(changes, args.verbose)) or "  no differences")
        return 0
    verdict = evaluate(changes, predictions.rules)
    print("\n".join(format_verdict(verdict, predictions.rules, changes, args.verbose, ignored)))
    return 0 if verdict.ok else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check", help="compare two copies of the goldens with a predictions file")
    check.add_argument("predictions", type=Path)
    diff = commands.add_parser("diff", help="print the observed changes without predictions")
    for sub in (check, diff):
        sub.add_argument("--old", default="HEAD", metavar="SPEC", help="the goldens before the recapture (default HEAD)")
        sub.add_argument("--new", default="WORKTREE", metavar="SPEC", help="the goldens after it (default WORKTREE)")
        sub.add_argument("--root", default=DEFAULT_ROOT, help=f"the golden folder inside the checkout (default {DEFAULT_ROOT})")
        sub.add_argument("-v", "--verbose", action="store_true", help="list every change one by one")
        sub.add_argument("--repo", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="backslashreplace")  # a golden value never makes the report itself fail
    try:
        return run(args)
    except SpecError as error:
        print(f"predictions: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
