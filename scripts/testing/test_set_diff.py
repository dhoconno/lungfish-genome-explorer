#!/usr/bin/env python3
"""List the tests a change lost, added or moved between two gate records.

Usage: test_set_diff.py <old gate.result.json> <new gate.result.json> [--allow <file>]

A record holds `harnesses` objects (a gate.result.json keeps one under
`attempts[*]`), and each harness holds `selectedTests` (written by harness_result in
scripts/release/gate_evidence.py), a list of names such as
`LungfishAppTests.ColumnFilterApplicationTests/batchClassificationNumericFilter()`.
The tool reads every `harnesses` object at any depth, and the union of their
`selectedTests` is the record's test set. The bundle prefix up to the first dot is
stripped, so a test is the key `Class/test`.

- GONE: a key in the old record and not in the new one.
- ADDED: a key in the new record and not in the old one.
- MOVED: a key in both records under a different set of bundles.

--allow names a file with one test a line, as `Class/test` or with its bundle
prefix. Blank lines and lines that start with `#` are skipped. A GONE key in that
file is printed as ALLOWED-GONE and does not fail the run.

Exit 0 when no GONE key is outside the allow list, 1 when one is, 2 when a record
cannot be read. The file's name starts with test_ because the plan names it so, so
it holds no function or class that a test runner would collect.
"""
import argparse
import json
import sys


def key_of(name):
    """`Bundle.Class/test` as (`Class/test`, `Bundle`). A name with no dot before its first slash has no bundle."""
    head, slash, tail = name.partition("/")
    bundle, dot, rest = head.partition(".")
    if not dot:
        return name, ""
    return rest + slash + tail, bundle


def harness_objects(node):
    """The harness objects under every `harnesses` key at any depth of a decoded record."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "harnesses" and isinstance(value, dict):
                yield from (harness for harness in value.values() if isinstance(harness, dict))
            else:
                yield from harness_objects(value)
    elif isinstance(node, list):
        for item in node:
            yield from harness_objects(item)


def read_record(path):
    """{key: set of bundles} over the union of every harness's selectedTests, or None with a message printed."""
    try:
        with open(path, encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, ValueError) as error:
        print(f"test_set_diff: cannot read {path}: {error}", file=sys.stderr)
        return None
    harnesses = list(harness_objects(record))
    if not harnesses:
        print(f"test_set_diff: {path} has no harnesses object, so it is not a gate.result.json", file=sys.stderr)
        return None
    keys = {}
    for harness in harnesses:
        for name in harness.get("selectedTests", []):
            key, bundle = key_of(name)
            keys.setdefault(key, set()).add(bundle)
    if not keys:
        print(f"test_set_diff: {path} selects no test in its harnesses", file=sys.stderr)
        return None
    return keys


def read_allow(path):
    allowed = set()
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line and not line.startswith("#"):
                allowed.update({line, key_of(line)[0]})
    return allowed


def compare(old, new):
    gone = sorted(key for key in old if key not in new)
    added = sorted(key for key in new if key not in old)
    moved = sorted(key for key in old if key in new and old[key] != new[key])
    return gone, added, moved


def main(argv):
    parser = argparse.ArgumentParser(prog="test_set_diff.py", description="List the tests a change lost, added or moved.")
    parser.add_argument("old", help="the old gate.result.json")
    parser.add_argument("new", help="the new gate.result.json")
    parser.add_argument("--allow", help="a file with one allowed GONE test a line, as Class/test")
    args = parser.parse_args(argv[1:])
    old, new = read_record(args.old), read_record(args.new)
    if old is None or new is None:
        return 2
    try:
        allowed = read_allow(args.allow) if args.allow else set()
    except OSError as error:
        print(f"test_set_diff: cannot read {args.allow}: {error}", file=sys.stderr)
        return 2
    gone, added, moved = compare(old, new)
    lost = [key for key in gone if key not in allowed]
    print(f"GONE {len(gone)} ({len(gone) - len(lost)} allowed)")
    for key in gone:
        print(f"  {'GONE' if key in lost else 'ALLOWED-GONE'} {key}")
    print(f"ADDED {len(added)}")
    for key in added:
        print(f"  ADDED {key}")
    print(f"MOVED {len(moved)}")
    for key in moved:
        print(f"  MOVED {key} {','.join(sorted(old[key]))} -> {','.join(sorted(new[key]))}")
    print(f"TEST-SET old {len(old)} new {len(new)}: " + (f"LOST {len(lost)}" if lost else "OK"))
    return 1 if lost else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
