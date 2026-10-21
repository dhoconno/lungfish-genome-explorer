#!/usr/bin/env python3
"""Fail a test tier that leaves UUID-named plists behind in ~/Library/Preferences or adds
org.lungfish. keys to the preferences domain of the xctest tool.

Phase 2.9 lane Q10, decision H1. A test that builds UserDefaults(suiteName: "<prefix>-<UUID>")
makes the system write ~/Library/Preferences/<prefix>-<UUID>.plist, and removePersistentDomain
only empties that file, so thousands piled up. The preferences daemon writes the emptied file
again seconds after a test removes it, so cleaning up by hand does not last. The shared helper
TestDefaultsSuite (Tests/Support/LungfishTestSupport) names its suite by a path in the temporary
directory, which keeps the plist out of the folder. This script is the check around it.
scripts/release/gate_evidence.py runs `snapshot` and `domain-snapshot` before the tests of every Swift
gate (a tier or a profile) and `check` and `domain-check` after their processes exit, and records a
failure as an error in gate.result.json.

  snapshot --output FILE   list the UUID-named plists now and write the list to FILE
  check --before FILE      wait for the system to settle, list them again, and fail on a new one
                           whose prefix some file under Tests builds by hand and the allowed list
                           lacks (a prefix a test passes to TestDefaultsSuite is another checkout's)
  lint                     fail when the allowed list names a file that no longer builds its prefix,
                           or a test file that calls UserDefaults(suiteName:) has no row
  prefixes                 print each prefix a file under Tests builds, and which file
  domain-snapshot --output FILE
                           write the names of the org.lungfish. keys of the domain
                           com.apple.dt.xctest.tool to FILE (`defaults export com.apple.dt.xctest.tool -`)
  domain-check --before FILE
                           read the domain again and fail on a key that begins org.lungfish. and is
                           not in FILE (Phase 2.13 lane 13.52, PREFS-XCTEST-DOMAIN)

Only names are compared. A new plist whose prefix no file under Tests builds belongs to another
app (com.openai.chat.RemoteFeatureFlags-<UUID>.plist) and is counted but never fails the tier.
A plist named by a bare UUID counts against the tests only when a test names a suite that way,
suiteName: UUID(). A test that names a temporary folder by a bare UUID does not make that prefix.
So does a new plist named for a prefix a test passes to TestDefaultsSuite when the allowed list
lacks it. The helper keeps its plist in the temporary directory and TestDefaultsSuiteTests fails
if it ever writes here, so a checkout that still builds that suite by hand wrote the file.

The allowed list (preferences-leaks-allowed.txt, beside this script) holds one row per test file
that still builds a "<prefix>-<UUID>" suite by hand. It can only shrink. `lint` fails on a row
whose file no longer builds that prefix by hand (it moved onto TestDefaultsSuite, so delete the
row) and on a test file that calls UserDefaults(suiteName:) and has no row, and a row is never
added: give the new test the helper.

A test host's UserDefaults.standard is the domain com.apple.dt.xctest.tool, which the plist check
cannot see, since its file keeps one name for ever. A table of a result view saves its column layout
there under org.lungfish.metadata-column-layout.<kind>:<result path> unless the test gives the
table's MetadataColumnController a suite. The domain commands compare key names only, as
`defaults export` reads them, and the gate runs them on a Mac where no other agent runs tests.

Exit status: 0 clean, 1 a leak, 3 the allowed list is stale or malformed, 4 unusable input.
LUNGFISH_PREFERENCES_DIR names another folder to list and LUNGFISH_PREFERENCES_SETTLE_SECONDS
the settle, both for this script's own tests. LUNGFISH_PREFERENCES_DOMAIN_EXPORT (or
--domain-export) names a plist file that stands in for `defaults export`. A run that sets
LUNGFISH_PREFERENCES_DIR and not that file reads com.apple.dt.xctest.tool.plist from the folder
(an absent file is an empty domain), so a test of the gate never reads the machine's own domain.
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import pwd
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import NamedTuple
from xml.parsers.expat import ExpatError

HERE = Path(__file__).resolve().parent
DEFAULT_TESTS = HERE.parents[1] / "Tests"
DEFAULT_ALLOWED = HERE / "preferences-leaks-allowed.txt"
NO_PREFIX = "(none)"
SKIPPED_DIRECTORIES = {".build", "Fixtures", "Resources"}
HELPER = "Tests/Support/LungfishTestSupport/TestDefaultsSuite.swift"

EXIT_CLEAN, EXIT_LEAK, EXIT_LIST, EXIT_INPUT = 0, 1, 3, 4

DOMAIN = "com.apple.dt.xctest.tool"
DOMAIN_KEY_PREFIX = "org.lungfish."
DEFAULTS = "/usr/bin/defaults"
DEFAULTS_TIMEOUT_SECONDS = 120
DOMAIN_KEYS_SHOWN = 20

UUID = r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
# <prefix>[-.]<UUID>[anything].plist
PLIST = re.compile(rf"^(?P<prefix>.*?)[-.]?{UUID}.*\.plist$")
# A Swift string literal whose text up to a UUID interpolation holds no other interpolation, a
# literal joined to a UUID with +, and a suite named by a bare UUID.
UUID_LITERAL = re.compile(r'"((?:[^"\\\n]|\\[^(\n])*)\\\(\s*UUID\(\)(?:\.uuidString)?\s*\)')
JOINED_LITERAL = re.compile(r'"((?:[^"\\\n]|\\[^(\n])*)"\s*\+\s*UUID\(\)(?:\.uuidString)?')
BARE_SUITE = re.compile(r'\bsuiteName:\s*UUID\(\)(?:\.uuidString)?')
# The helper's two entry points, with the prefix as a literal.
HELPER_CALL = re.compile(r'\b(?:TestDefaultsSuite|makeTestDefaultsSuite)\(\s*prefix:\s*"([^"\\\n]*)"')


class AllowedListError(Exception):
    """The allowed list cannot be read."""


class Row(NamedTuple):
    prefix: str
    file: str
    line: int


def plist_prefix(name: str) -> str | None:
    """The prefix of a UUID-named plist, "" for a bare UUID, None for any other file."""
    match = PLIST.match(name)
    return None if match is None else match.group("prefix")


def preferences_directory(option: Path | None) -> Path:
    if option is not None:
        return option
    if os.environ.get("LUNGFISH_PREFERENCES_DIR"):
        return Path(os.environ["LUNGFISH_PREFERENCES_DIR"])
    # The real home, as the daemon that writes the files sees it, whatever HOME says.
    return Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library" / "Preferences"


def scan(directory: Path) -> dict[str, str]:
    """Every UUID-named plist in `directory`, as name -> prefix."""
    try:
        names = os.listdir(directory)
    except FileNotFoundError:
        return {}
    found = {}
    for name in names:
        prefix = plist_prefix(name)
        if prefix is not None:
            found[name] = prefix
    return found


def without_separator(text: str) -> str:
    return text[:-1] if text.endswith(("-", ".")) else text


class Built(NamedTuple):
    """What the Swift files under Tests build, each prefix with the files that build it."""

    by_hand: dict[str, set[str]]  # "<prefix>-<UUID>" or "<prefix>.<UUID>" in a string literal
    by_helper: dict[str, set[str]]  # a prefix passed to TestDefaultsSuite
    suite_files: set[str]  # files that call UserDefaults(suiteName:) themselves

    @property
    def prefixes(self) -> set[str]:
        return set(self.by_hand) | set(self.by_helper)


def scan_tests(tests_root: Path) -> Built:
    """Read the Swift files under `tests_root`. A literal that names a temporary folder counts as
    built by hand too, which only makes the check count more prefixes. A literal that begins at the
    UUID makes no prefix, and only a suite named by a bare UUID makes the empty one."""
    repo = tests_root.parent
    by_hand: dict[str, set[str]] = {}
    by_helper: dict[str, set[str]] = {}
    suite_files: set[str] = set()
    for folder, folders, files in os.walk(tests_root):
        folders[:] = sorted(name for name in folders if name not in SKIPPED_DIRECTORIES)
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = Path(folder) / name
            text = path.read_text(encoding="utf-8", errors="replace")
            relative = path.relative_to(repo).as_posix()
            for pattern in (UUID_LITERAL, JOINED_LITERAL):
                for match in pattern.finditer(text):
                    prefix = without_separator(match.group(1))
                    # A literal that begins at the UUID, "\(UUID().uuidString)", names a temporary folder or
                    # file in 13 test files and says nothing about a suite, so it makes no prefix. Were the
                    # empty prefix made here, every bare-UUID plist of another app would count against them.
                    if prefix:
                        by_hand.setdefault(prefix, set()).add(relative)
            if BARE_SUITE.search(text):
                by_hand.setdefault("", set()).add(relative)
            for match in HELPER_CALL.finditer(text):
                by_helper.setdefault(match.group(1), set()).add(relative)
            if "UserDefaults(suiteName:" in text and relative != HELPER:
                suite_files.add(relative)
    return Built(by_hand, by_helper, suite_files)


def load_allowed(path: Path) -> list[Row]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise AllowedListError(f"cannot read the allowed list {path}: {error}") from error
    rows = []
    for number, raw in enumerate(lines, 1):
        words = raw.split("#", 1)[0].split()
        if not words:
            continue
        if len(words) != 2:
            raise AllowedListError(f"{path.name}:{number}: expected '<prefix> <file>', found {raw!r}")
        rows.append(Row("" if words[0] == NO_PREFIX else words[0], words[1], number))
    return rows


def lint(rows: list[Row], built: Built, repo: Path, label: str = "allowed list") -> list[str]:
    """Problems that keep the allowed list from being the list of what tests still build by hand.

    A row names a file that still builds its prefix, and a file that calls
    UserDefaults(suiteName:) itself has a row, so the list can neither keep a file that moved onto
    TestDefaultsSuite nor miss a new test that did not.
    """
    problems = []
    seen = set()
    for row in rows:
        where = f"{label}:{row.line}"
        shown = row.prefix or NO_PREFIX
        if (row.prefix, row.file) in seen:
            problems.append(f"{where}: {shown} {row.file} is listed twice")
        seen.add((row.prefix, row.file))
        if not (repo / row.file).is_file():
            problems.append(f"{where}: {row.file} does not exist, delete the row")
        elif row.file not in built.by_hand.get(row.prefix, set()):
            problems.append(
                f"{where}: {row.file} no longer builds '{shown}-<UUID>' by hand, delete the row"
            )
    for file in sorted(built.suite_files - {row.file for row in rows}):
        problems.append(f"{file} calls UserDefaults(suiteName:) and is not on the {label}, use TestDefaultsSuite instead")
    return problems


def read_snapshot(path: Path, directory: Path) -> set[str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        names, listed = set(data["names"]), data["directory"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ValueError(f"cannot read the snapshot {path}: {error}") from error
    if listed != str(directory):
        raise ValueError(f"the snapshot {path} lists {listed}, not {directory}")
    return names


def group(found: dict[str, str], names: list[str]) -> dict[str, list[str]]:
    grouped: dict[str, list[str]] = {}
    for name in names:
        grouped.setdefault(found[name], []).append(name)
    return grouped


def verdict(directory, before, first, after, built: Built, allowed: set[str]) -> tuple[int, list[str]]:
    prefixes = built.prefixes
    new = [name for name in sorted(after) if name not in before]
    foreign = [n for n in new if after[n] not in prefixes]
    tolerated = [n for n in new if after[n] in prefixes and after[n] in allowed]
    # TestDefaultsSuite keeps its plist in the temporary directory, and TestDefaultsSuiteTests fails
    # if it ever writes here, so a plist named for a prefix this tree passes to the helper was
    # written by another checkout that still builds that suite by hand.
    elsewhere = [n for n in new if after[n] in built.by_helper and after[n] not in allowed]
    leaked = [n for n in new
              if after[n] in prefixes and after[n] not in allowed and after[n] not in built.by_helper]
    lines = []
    moved = set(first) ^ set(after)
    if moved:
        lines.append(f"preferences-leaks: {len(moved)} plist(s) appeared or went away during the settle")
    summary = f"{len(new)} new UUID-named plists in {directory}"
    if not leaked:
        notes = []
        if tolerated:
            notes.append(f"{len(tolerated)} on the allowed list")
        if foreign:
            notes.append(f"{len(foreign)} from other apps")
        if elsewhere:
            notes.append(f"{len(elsewhere)} from another checkout, named for a TestDefaultsSuite prefix")
        lines.append(f"preferences-leaks: PASS - {summary}" + (f" ({', '.join(notes)})" if notes else ""))
        for prefix, names in sorted(group(after, tolerated).items(), key=lambda item: -len(item[1]))[:10]:
            lines.append(f"  allowed  {len(names):5d}  {prefix or NO_PREFIX}")
        return EXIT_CLEAN, lines
    lines.append(f"preferences-leaks: FAIL - {summary}, {len(leaked)} of them from tests that do not clean up")
    for prefix, names in sorted(group(after, leaked).items()):
        files = sorted(built.by_hand.get(prefix, set()) | built.by_helper.get(prefix, set()))
        lines.append(f"  {len(names):5d}  {names[0]}")
        lines.append(f"         built by {', '.join(files[:3])}" + (" and others" if len(files) > 3 else ""))
    lines.append(
        f"A test that needs a defaults suite uses TestDefaultsSuite ({HELPER}), which keeps the plist "
        "out of this folder. Never add a prefix to the allowed list."
    )
    return EXIT_LEAK, lines


def emit(lines: list[str], report: Path | None, failed: bool, append: bool = False) -> None:
    """Print the verdict, and keep a failing one in `report` for a run whose output is discarded.
    The domain check appends, since the plist check of the same run may already have written there."""
    print("\n".join(lines), file=sys.stderr if failed else sys.stdout)
    if failed and report is not None:
        report.parent.mkdir(parents=True, exist_ok=True)
        with report.open("a" if append else "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")


def allowed_problems(args) -> tuple[list[Row], list[str]]:
    rows = load_allowed(args.allowed)
    return rows, lint(rows, scan_tests(args.tests_root), args.tests_root.parent, args.allowed.name)


def command_snapshot(args, sleep) -> int:
    directory = preferences_directory(args.preferences_dir)
    _, problems = allowed_problems(args)
    if problems:
        emit(["preferences-leaks: the allowed list is stale", *problems], args.report, True)
        return EXIT_LIST
    names = sorted(scan(directory))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"schema": 1, "directory": str(directory), "names": names}) + "\n")
    print(f"preferences-leaks: {len(names)} UUID-named plists in {directory} before the tier")
    return EXIT_CLEAN


def command_check(args, sleep) -> int:
    directory = preferences_directory(args.preferences_dir)
    before = read_snapshot(args.before, directory)
    first = scan(directory)
    sleep(args.settle)
    after = scan(directory)
    allowed = {row.prefix for row in load_allowed(args.allowed)}
    status, lines = verdict(directory, before, first, after, scan_tests(args.tests_root), allowed)
    emit(lines, args.report, status != EXIT_CLEAN)
    return status


def domain_export_file(option: Path | None) -> tuple[Path | None, bool]:
    """The plist file that stands in for `defaults export`, and whether a missing file is an empty
    domain. The option wins, then LUNGFISH_PREFERENCES_DOMAIN_EXPORT. A run that lists a fixture
    folder (LUNGFISH_PREFERENCES_DIR) reads the domain's plist from it, so a test of the gate never
    reads the machine's own domain. None means the real domain."""
    if option is not None:
        return option, False
    if os.environ.get("LUNGFISH_PREFERENCES_DOMAIN_EXPORT"):
        return Path(os.environ["LUNGFISH_PREFERENCES_DOMAIN_EXPORT"]), False
    if os.environ.get("LUNGFISH_PREFERENCES_DIR"):
        return Path(os.environ["LUNGFISH_PREFERENCES_DIR"]) / f"{DOMAIN}.plist", True
    return None, False


def read_domain(option: Path | None) -> dict:
    """The keys of the xctest tool's domain, from `defaults export com.apple.dt.xctest.tool -`."""
    source, empty_if_missing = domain_export_file(option)
    if source is None:
        try:
            done = subprocess.run([DEFAULTS, "export", DOMAIN, "-"], capture_output=True, check=False,
                                  timeout=DEFAULTS_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired as error:
            raise ValueError(f"defaults export {DOMAIN} did not end in {DEFAULTS_TIMEOUT_SECONDS} s") from error
        if done.returncode != 0:
            detail = done.stderr.decode("utf-8", "replace").strip()
            raise ValueError(f"defaults export {DOMAIN} exited {done.returncode}: {detail}")
        data = done.stdout
    elif empty_if_missing and not source.exists():
        return {}
    else:
        data = source.read_bytes()
    try:
        domain = plistlib.loads(data)
    except (ValueError, ExpatError) as error:
        raise ValueError(f"cannot read the export of {DOMAIN}: {error}") from error
    if not isinstance(domain, dict):
        raise ValueError(f"the export of {DOMAIN} is not a dictionary")
    return domain


def domain_names(domain: dict) -> list[str]:
    return sorted(key for key in domain if isinstance(key, str) and key.startswith(DOMAIN_KEY_PREFIX))


def read_domain_snapshot(path: Path) -> set[str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        names, listed = set(data["names"]), data["domain"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ValueError(f"cannot read the domain snapshot {path}: {error}") from error
    if listed != DOMAIN:
        raise ValueError(f"the domain snapshot {path} lists {listed}, not {DOMAIN}")
    return names


def command_domain_snapshot(args, sleep) -> int:
    names = domain_names(read_domain(args.domain_export))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"schema": 1, "domain": DOMAIN, "names": names}) + "\n")
    print(f"preferences-leaks: {len(names)} {DOMAIN_KEY_PREFIX} keys in {DOMAIN} before the tier")
    return EXIT_CLEAN


def command_domain_check(args, sleep) -> int:
    before = read_domain_snapshot(args.before)
    after = domain_names(read_domain(args.domain_export))
    new = [name for name in after if name not in before]
    if not new:
        emit([f"preferences-leaks: PASS - 0 new {DOMAIN_KEY_PREFIX} keys in {DOMAIN} "
              f"({len(after)} now, {len(before)} before)"], args.report, False)
        return EXIT_CLEAN
    lines = [f"preferences-leaks: FAIL - {len(new)} new {DOMAIN_KEY_PREFIX} keys in {DOMAIN}, "
             "from tests that write UserDefaults.standard"]
    lines += [f"  {name}" for name in new[:DOMAIN_KEYS_SHOWN]]
    if len(new) > DOMAIN_KEYS_SHOWN:
        lines.append(f"  and {len(new) - DOMAIN_KEYS_SHOWN} more")
    lines.append("A test that opens a result view gives its tables a suite from TestDefaultsSuite "
                 "(MetadataColumnController.userDefaults), so no layout reaches this domain.")
    emit(lines, args.report, True, append=True)
    return EXIT_LEAK


def command_lint(args, sleep) -> int:
    rows, problems = allowed_problems(args)
    if problems:
        emit(["preferences-leaks: the allowed list is stale", *problems], None, True)
        return EXIT_LIST
    print(f"preferences-leaks: {len(rows)} rows on the allowed list, each names a file that still builds its prefix")
    return EXIT_CLEAN


def command_prefixes(args, sleep) -> int:
    built = scan_tests(args.tests_root)
    for origin, found in (("by-hand", built.by_hand), ("helper", built.by_helper)):
        for prefix in sorted(found):
            for file in sorted(found[prefix]):
                print(f"{prefix or NO_PREFIX}\t{file}\t{origin}")
    return EXIT_CLEAN


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--preferences-dir", type=Path, help="the folder to list (default ~/Library/Preferences)")
    common.add_argument("--tests-root", type=Path, default=DEFAULT_TESTS)
    common.add_argument("--allowed", type=Path, default=DEFAULT_ALLOWED)
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    snapshot = commands.add_parser("snapshot", parents=[common])
    snapshot.add_argument("--output", type=Path, required=True)
    snapshot.add_argument("--report", type=Path, help="also write a stale-list message to this file")
    check = commands.add_parser("check", parents=[common])
    check.add_argument("--before", type=Path, required=True)
    check.add_argument("--settle", type=float, default=float(os.environ.get("LUNGFISH_PREFERENCES_SETTLE_SECONDS", "3")))
    check.add_argument("--report", type=Path, help="also write the verdict to this file")
    domain = argparse.ArgumentParser(add_help=False)
    domain.add_argument("--domain-export", type=Path,
                        help="a plist file to read in place of `defaults export com.apple.dt.xctest.tool -`")
    domain.add_argument("--report", type=Path, help="also write a failing verdict to this file")
    domain_snapshot = commands.add_parser("domain-snapshot", parents=[domain])
    domain_snapshot.add_argument("--output", type=Path, required=True)
    domain_check = commands.add_parser("domain-check", parents=[domain])
    domain_check.add_argument("--before", type=Path, required=True)
    commands.add_parser("lint", parents=[common])
    commands.add_parser("prefixes", parents=[common])
    return parser


COMMANDS = {
    "snapshot": command_snapshot, "check": command_check, "lint": command_lint, "prefixes": command_prefixes,
    "domain-snapshot": command_domain_snapshot, "domain-check": command_domain_check,
}


def main(argv: list[str] | None = None, sleep=time.sleep) -> int:
    args = build_parser().parse_args(argv)
    try:
        return COMMANDS[args.command](args, sleep)
    except AllowedListError as error:
        print(f"preferences-leaks: {error}", file=sys.stderr)
        return EXIT_LIST
    except (OSError, ValueError) as error:
        print(f"preferences-leaks: {error}", file=sys.stderr)
        return EXIT_INPUT


if __name__ == "__main__":
    sys.exit(main())
