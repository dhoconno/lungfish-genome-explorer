#!/usr/bin/env python3
"""Check that projects made by older releases open and export the same in a candidate build.

    python3 scripts/golden/upgrade_check.py --cli PATH [--corpus DIR] [--only RELEASE[/PROJECT]]
    python3 scripts/golden/upgrade_check.py --capture --cli OLD_CLI --only RELEASE [--corpus DIR]

The corpus sits in /Users/Shared/lungfish-golden/cache/upgrade-corpus/. Each
<release>/<project id>/ folder holds one project that release's lungfish-cli
built and an expected/ folder with what that same CLI gave for it. The check
copies each project to a scratch folder, runs the same steps with the candidate
CLI (list the results, provenance verify each result, export every table),
applies the golden normalization rules (scripts/golden/normalize.py) and
compares byte for byte. It prints one line per difference and exits 1 on any.
Exit 2 means the corpus is missing or damaged. --capture writes expected/ for a
release with its own CLI and is only for building the corpus.

Three rules of its own keep what a build says about itself out of the diff,
because the checking build is not the build that made the project:
- the app version of the build that made the project (from expected/_run.json)
  is masked as well as the checking build's, and the build label after a version
  ("(12972)" in a release, "(dev)" in a debug build) becomes <BUILD>;
- the CLI path is not masked, because a project's records hold the path of the
  CLI that made it and the checking CLI has another path;
- the SHA-256 and size of a file record whose path is in the step's own output
  folder are masked, because that file holds the time, a random ID, the scratch
  folder and the exporting build. Its text is compared in full. The digest and
  size of a project file the step only reads stay compared.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
sys.dont_write_bytecode = True

import normalize  # noqa: E402

CORPUS = Path("/Users/Shared/lungfish-golden/cache/upgrade-corpus")
BUILD_COMMAND = "bash scripts/golden/build_upgrade_corpus.sh <release tag> <that release's lungfish-cli>"
RESULT_SUFFIXES = (".lungfishref", ".lungfishfastq", ".lungfishmsa", ".lungfishtree", ".lungfishprimers",
                   ".lungfishprimeranalysis", ".lungfishmhcref", ".lungfishgenotype", ".lungfish12s",
                   ".lungfish12sref", ".lungfishtax", ".lungfishrun")
MAX_LINES_PER_FILE = 10
STEP_SECONDS = 900
WRITTEN_FILE_PREFIX = normalize.RUN_ROOT_TOKEN + "/out/"
WRITTEN_HASH_TOKEN = '"<SHA256-WRITTEN>"'
WRITTEN_SIZE_TOKEN = '"<SIZE-WRITTEN>"'
BUILD_LABEL = re.compile(re.escape(normalize.APP_VERSION_TOKEN) + r" \([^)\"\\]*\)")
BUILD_LABEL_TOKEN = normalize.APP_VERSION_TOKEN + " (<BUILD>)"


class CorpusError(Exception):
    pass


def find_results(project: Path) -> list[str]:
    """Every result folder of a project: a bundle of a known kind or a folder directly under Analyses."""
    return [path.relative_to(project).as_posix() for path in sorted(project.rglob("*"))
            if path.is_dir() and (path.name.endswith(RESULT_SUFFIXES) or path.parent.name == "Analyses")]


def plan(project: Path) -> list[tuple[str, list[str]]]:
    """The steps for a project. {P} is the project copy and {OUT} an output folder the step may write."""
    steps = [("universal-search", ["universal-search", "{P}", "--reindex", "--format", "tsv", "--limit", "100000"]),
             ("ops-stats", ["ops", "stats", "{P}"])]
    for rel in find_results(project):
        steps.append((f"verify {rel}", ["provenance", "verify", "{P}/" + rel]))
        steps.append((f"export {rel}", ["provenance", "export", "{P}/" + rel, "--format", "json", "--output", "{OUT}"]))
        if rel.endswith(".lungfishref"):
            steps.append((f"info {rel}", ["bundle", "info", "{P}/" + rel, "--format", "json"]))
            steps.append((f"tracks {rel}", ["bundle", "list", "{P}/" + rel, "--format", "tsv"]))
    return steps


def cli_version(cli: Path) -> str:
    done = subprocess.run([str(cli), "--version"], capture_output=True, text=True, timeout=120)
    version = done.stdout.strip()
    if done.returncode != 0 or not version or "\n" in version:
        raise CorpusError(f"upgrade-check: {cli} --version failed: {done.stdout}{done.stderr}")
    return version


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


@dataclass
class StepRun:
    """One CLI call: the argv shape, the exit code, both streams and every file it wrote."""

    argv: str
    code: str
    out: str
    err: str
    files: list[tuple[str, str]]


def run_step(cli: Path, argv: list[str], project: Path, scratch: Path, index: int) -> StepRun:
    out_dir = scratch / "out" / f"{index:03d}"
    out_dir.mkdir(parents=True)
    args = [a.replace("{P}", str(project)).replace("{OUT}", str(out_dir / "export")) for a in argv]
    env = {"HOME": str(Path.home()), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(scratch / "tmp") + "/",
           "LANG": "en_US.UTF-8"}
    try:
        done = subprocess.run([str(cli), *args], capture_output=True, text=True, cwd=scratch, env=env,
                              timeout=STEP_SECONDS)
        code, out, err = str(done.returncode), done.stdout, done.stderr
    except subprocess.TimeoutExpired:
        code, out, err = "timeout", "", f"no answer in {STEP_SECONDS} s\n"
    files = [(path.relative_to(out_dir).as_posix(), path.read_bytes().decode("utf-8", "replace"))
             for path in sorted(out_dir.rglob("*")) if path.is_file()]
    return StepRun(" ".join(argv), code, out, err, files)


def mask_written_files(text: str) -> str:
    """The SHA-256 and size of each file record whose path is in the step's output folder become tokens."""
    root = normalize.parse_json(text)
    if root is None:
        return text
    edits: dict[tuple[int, int], str] = {}
    for record in normalize.file_records(root):
        if not str(record.get("path").value).startswith(WRITTEN_FILE_PREFIX):
            continue
        for keys, token in ((normalize.HASH_KEYS, WRITTEN_HASH_TOKEN), (normalize.SIZE_KEYS, WRITTEN_SIZE_TOKEN)):
            for key in keys:
                node = record.get(key)
                if node is not None:
                    edits[(node.start, node.end)] = token
    return normalize.apply_edits(text, edits)


def normalize_text(normalizer: normalize.Normalizer, other_versions: list[str], text: str) -> str:
    """The golden rules, then the version of the build that made the project, the build labels and the written files' digests."""
    text = normalizer.text(text)
    for version in other_versions:
        text = normalize.mask_app_version(text, version)
    return mask_written_files(BUILD_LABEL.sub(BUILD_LABEL_TOKEN, text))


def run_plan(cli: Path, version: str, project_dir: Path, scratch: Path, other_versions: list[str]) -> dict[str, str]:
    """Copy the project into scratch, run every step and return the normalized record of each by file name.

    other_versions are the app versions of the builds that made the project or its expected/ output.
    """
    (scratch / "tmp").mkdir(parents=True)
    project = scratch / "project" / project_dir.name
    shutil.copytree(project_dir, project, symlinks=True)
    normalizer = normalize.Normalizer(run_root=str(scratch), app_version=version, lock_sha256=None)
    others = [other for other in other_versions if other != version]
    records: dict[str, str] = {}
    for index, (name, argv) in enumerate(plan(project)):
        step = run_step(cli, argv, project, scratch, index)
        record = (f"argv: {step.argv}\nexit: {step.code}\n--- stdout\n{normalize_text(normalizer, others, step.out)}"
                  f"--- stderr\n{normalize_text(normalizer, others, step.err)}")
        for path, text in step.files:
            record += f"--- file {path}\n{normalize_text(normalizer, others, text)}"
        records[f"{index:03d}-{re.sub(r'[^A-Za-z0-9._-]+', '_', name)[:90]}.txt"] = record
    return records


def captured_versions(expected_dir: Path) -> list[str]:
    """The version of the CLI that wrote expected/, which is also the version of the build that made the project."""
    try:
        return [str(json.loads((expected_dir / "_run.json").read_text())["cliVersion"])]
    except (OSError, ValueError, KeyError):
        return []


def compare(label: str, expected: dict[str, str], actual: dict[str, str]) -> list[str]:
    """One line per differing line, at most MAX_LINES_PER_FILE a file, and one line per missing or extra step."""
    lines: list[str] = []
    for name in sorted(set(expected) | set(actual)):
        if name not in actual:
            lines.append(f"{label}/{name}: expected step was not run")
        elif name not in expected:
            lines.append(f"{label}/{name}: step is not in expected/")
        elif expected[name] != actual[name]:
            before, after = expected[name].splitlines(), actual[name].splitlines()
            shown = 0
            for number in range(max(len(before), len(after))):
                old = before[number] if number < len(before) else "<no line>"
                new = after[number] if number < len(after) else "<no line>"
                if old != new:
                    shown += 1
                    if shown <= MAX_LINES_PER_FILE:
                        lines.append(f"{label}/{name} line {number + 1}: expected {old[:140]!r} got {new[:140]!r}")
            if shown > MAX_LINES_PER_FILE:
                lines.append(f"{label}/{name}: {shown - MAX_LINES_PER_FILE} more differing lines")
            if shown == 0:
                lines.append(f"{label}/{name}: differs only in the line ends or the last newline")
    return lines


def corpus_entries(corpus: Path, only: str | None, need_expected: bool) -> list[tuple[str, Path, Path]]:
    if not corpus.is_dir() or not any(corpus.glob("*/*/*.lungfish")):
        raise CorpusError(f"upgrade-check: the corpus is missing at {corpus}. Build it with `{BUILD_COMMAND}`, "
                          "once for Stable v2026.11.7 and once for Preview v2026.11.6")
    entries = []
    for project in sorted(corpus.glob("*/*/*.lungfish")):
        label = f"{project.parent.parent.name}/{project.parent.name}"
        if only and label != only and not label.startswith(only + "/"):
            continue
        expected = project.parent / "expected"
        if need_expected and not any(expected.glob("*.txt")):
            raise CorpusError(f"upgrade-check: {label} has no expected/ output. Rebuild it with `{BUILD_COMMAND}`")
        entries.append((label, project, expected))
    if not entries:
        raise CorpusError(f"upgrade-check: no corpus project matches --only {only}")
    return entries


def verify_sums(corpus: Path) -> None:
    sums = corpus / "SHA256SUMS"
    if not sums.is_file():
        raise CorpusError(f"upgrade-check: {sums} is missing. Rebuild the corpus with `{BUILD_COMMAND}`")
    listed = {rel: digest for digest, _, rel in (line.partition("  ") for line in sums.read_text().splitlines())}
    present = {p.relative_to(corpus).as_posix() for p in corpus.rglob("*")
               if p.is_file() and p.name not in ("SHA256SUMS", ".DS_Store")}
    problems = [f"{rel}: not in SHA256SUMS" for rel in sorted(present - set(listed))]
    problems += [f"{rel}: missing" for rel in sorted(set(listed) - present)]
    problems += [f"{rel}: SHA-256 differs" for rel in sorted(set(listed) & present)
                 if sha256_of(corpus / rel) != listed[rel]]
    if problems:
        raise CorpusError("upgrade-check: the corpus does not match its SHA256SUMS\n"
                          + "".join(f"  {p}\n" for p in problems[:20]) + f"upgrade-check: rebuild it with `{BUILD_COMMAND}`")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cli", type=Path, required=True, help="the lungfish-cli to check (with --capture, the old release's)")
    parser.add_argument("--corpus", type=Path, default=CORPUS)
    parser.add_argument("--only", help="a release such as v2026.11.7, or release/project id")
    parser.add_argument("--capture", action="store_true", help="write expected/ with this CLI, to build the corpus")
    args = parser.parse_args(argv)
    cli = args.cli.expanduser().resolve()
    started = time.monotonic()
    try:
        if not cli.exists():
            raise CorpusError(f"upgrade-check: {cli} does not exist")
        entries = corpus_entries(args.corpus, args.only, need_expected=not args.capture)
        if not args.capture:
            verify_sums(args.corpus)
        version = cli_version(cli)
    except CorpusError as error:
        print(error, file=sys.stderr)
        return 2
    print(f"upgrade-check: {'capture' if args.capture else 'check'} with {cli} (version {version})", flush=True)
    differences: list[str] = []
    steps = 0
    for label, project_dir, expected_dir in entries:
        began = time.monotonic()
        scratch = Path(os.path.realpath(tempfile.mkdtemp(prefix="upgrade-check-")))
        try:
            records = run_plan(cli, version, project_dir, scratch, [] if args.capture else captured_versions(expected_dir))
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
        steps += len(records)
        if args.capture:
            shutil.rmtree(expected_dir, ignore_errors=True)
            expected_dir.mkdir(parents=True)
            for name, text in records.items():
                (expected_dir / name).write_text(text)
            zero = sum(1 for text in records.values() if "\nexit: 0\n" in text)
            (expected_dir / "_run.json").write_text(json.dumps({"cliVersion": version, "steps": len(records), "exitZero": zero}) + "\n")
            verdict = f"captured ({zero} exit 0)"
        else:
            found = compare(label, {p.name: p.read_text() for p in sorted(expected_dir.glob("*.txt"))}, records)
            differences += found
            verdict = f"{len(found)} differences" if found else "match"
        print(f"[{label}] {len(records)} steps {verdict} in {time.monotonic() - began:.1f} s", flush=True)
    for line in differences:
        print(line)
    state = "captured" if args.capture else ("FAILED" if differences else "passed")
    print(f"upgrade-check: {state}, {len(entries)} projects, {steps} steps, {len(differences)} differences "
          f"in {time.monotonic() - started:.1f} s", flush=True)
    return 1 if differences else 0


if __name__ == "__main__":
    sys.exit(main())
