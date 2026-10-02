#!/usr/bin/env python3
"""Capture and compare the Phase 1 golden fixtures.

    python3 scripts/golden/golden.py compare [--only NAME] [--cli PATH] [--strict]
    python3 scripts/golden/golden.py capture [--only NAME] [--cli PATH]

`compare` reruns every capture through lungfish-cli in a fresh scratch folder,
normalizes the outputs and diffs them against Tests/Fixtures/golden. It prints a
unified diff and exits 1 on any difference. `capture` rewrites the goldens and
is only for a deliberate, reviewed update. --strict leaves out the normalization
rules that still wait for a ruling, to show what they hide.

Without --cli the command builds lungfish-cli from this checkout with
`swift build --skip-update --product lungfish-cli --package-path <repo root>`.
Downloads are cached in ~/Library/Caches/lungfish-golden and checked by SHA-256.
The scratch folder of the last run stays in that cache folder until the next
run, and the hidden --replay option normalizes such a kept folder again without
rerunning any tool. Tests/Fixtures/golden/README.md describes each capture and
every normalization rule.
"""

from __future__ import annotations

import argparse
import difflib
import fcntl
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
sys.dont_write_bytecode = True

import captures  # noqa: E402
import normalize  # noqa: E402

REPO_ROOT = SCRIPT_DIR.parents[1]
GOLDEN_ROOT = REPO_ROOT / "Tests" / "Fixtures" / "golden"
CACHE_ROOT = Path.home() / "Library" / "Caches" / "lungfish-golden"
# The scratch root is a fixed folder that is emptied before each run. A fixed
# path keeps the bytes of outputs that embed their own paths (BAM headers,
# provenance hashes of those files) identical from run to run.
RUN_ROOT_NAME = "run"
MAX_GOLDEN_FILE_BYTES = 1_000_000
MAX_DIFF_LINES_PER_FILE = 400


def build_cli() -> Path:
    command = ["swift", "build", "--skip-update", "--product", "lungfish-cli", "--package-path", str(REPO_ROOT)]
    print("building:", " ".join(command), flush=True)
    subprocess.run(command, check=True)
    bin_path = subprocess.run(command + ["--show-bin-path"], check=True, capture_output=True, text=True).stdout.strip()
    cli = Path(bin_path) / "lungfish-cli"
    if not cli.exists():
        raise SystemExit(f"golden: build finished but {cli} does not exist")
    return cli


def clone(source: Path, destination: Path) -> None:
    """APFS clone when possible, so staging the 200 MB debug binary is free."""
    if subprocess.run(["/bin/cp", "-c", "-R", str(source), str(destination)], capture_output=True).returncode == 0:
        return
    if source.is_dir():
        shutil.copytree(source, destination, symlinks=True)
    else:
        shutil.copy2(source, destination)


def stage_cli(cli: Path, run_root: Path) -> Path:
    """Place the CLI inside the scratch root.

    Provenance records the executable path, so running the CLI from its build
    folder would write the checkout's path into every golden. The CLI's
    resource bundles sit next to it, so they are staged too.
    """
    source = cli.resolve()
    if any(part.endswith(".app") for part in source.parts):
        print(f"golden: warning: {source} is inside an app bundle and runs in place; "
              "its executable path differs from the goldens", file=sys.stderr)
        return source
    bin_dir = run_root / "bin"
    bin_dir.mkdir(parents=True)
    clone(source, bin_dir / "lungfish-cli")
    for bundle in sorted(source.parent.glob("*.bundle")):
        clone(bundle, bin_dir / bundle.name)
    return bin_dir / "lungfish-cli"


def cli_version(cli: Path) -> str:
    """What `lungfish-cli --version` prints. Q3 masks this exact string under
    the keys that record the LGE app or CLI version."""
    completed = subprocess.run([str(cli), "--version"], capture_output=True, text=True,
                               env={"HOME": str(Path.home()), "PATH": captures.BARE_PATH})
    version = completed.stdout.strip()
    if completed.returncode != 0 or not version or "\n" in version:
        raise SystemExit(f"golden: {cli} --version failed: {completed.stdout}{completed.stderr}")
    return version


def golden_files(directory: Path) -> dict[str, bytes]:
    if not directory.is_dir():
        return {}
    return {
        path.relative_to(directory).as_posix(): path.read_bytes()
        for path in sorted(directory.rglob("*"))
        if path.is_file()
    }


def display_lines(name: str, data: bytes) -> list[str]:
    """Lines for the printed diff only. XML parts and compact JSON payloads are
    one long line, so they are split between elements to make the diff readable."""
    text = data.decode("utf-8", "replace")
    if name.endswith((".xml", ".rels")):
        text = text.replace("><", ">\n<")
    elif "/captured-inputs/" in f"/{name}" and "\n" not in text.rstrip("\n"):
        text = text.replace(',"', ',\n"')
    return text.splitlines(keepends=True)


def diff_capture(name: str, expected: dict[str, bytes], actual: dict[str, bytes]) -> list[str]:
    report: list[str] = []
    for relpath in sorted(set(expected) | set(actual)):
        before, after = expected.get(relpath), actual.get(relpath)
        if before == after:
            continue
        label = f"{name}/{relpath}"
        if before is None:
            report.append(f"+++ new file not in the goldens: {label}\n")
            continue
        if after is None:
            report.append(f"--- golden file not produced: {label}\n")
            continue
        lines = list(
            difflib.unified_diff(
                display_lines(relpath, before),
                display_lines(relpath, after),
                fromfile=f"golden/{label}",
                tofile=f"run/{label}",
                n=2,
            )
        )
        if not lines:
            lines = [f"--- golden/{label}\n+++ run/{label}\n", "(byte difference outside the printed lines, such as line endings)\n"]
        if len(lines) > MAX_DIFF_LINES_PER_FILE:
            lines = lines[:MAX_DIFF_LINES_PER_FILE] + [f"... diff truncated, {len(lines) - MAX_DIFF_LINES_PER_FILE} more lines\n"]
        report.extend(line if line.endswith("\n") else line + "\n" for line in lines)
    return report


def portability_problems(name: str, outputs: dict[str, bytes], run_root: Path) -> list[str]:
    """Paths that would make the goldens differ between checkouts or runs."""
    problems = []
    needles = {str(REPO_ROOT): "this checkout's path", str(run_root): "the raw scratch root"}
    for relpath, data in outputs.items():
        if len(data) > MAX_GOLDEN_FILE_BYTES:
            problems.append(f"{name}/{relpath} is {len(data)} bytes, over the {MAX_GOLDEN_FILE_BYTES} byte limit")
        text = data.decode("utf-8", "replace")
        for needle, what in needles.items():
            if needle in text:
                problems.append(f"{name}/{relpath} contains {what} ({needle})")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=("compare", "capture"))
    parser.add_argument("--only", action="append", choices=sorted(captures.CAPTURES), metavar="CAPTURE",
                        help="run only this capture (repeatable): " + ", ".join(captures.CAPTURES))
    parser.add_argument("--cli", type=Path, help="use this lungfish-cli instead of building one from this checkout")
    parser.add_argument("--strict", action="store_true",
                        help="leave out the normalization rules that still wait for a ruling")
    parser.add_argument("--golden-dir", type=Path, default=GOLDEN_ROOT, help=argparse.SUPPRESS)
    parser.add_argument("--replay", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.mode == "capture" and args.strict:
        parser.error("--strict applies to compare only")

    names = args.only or list(captures.CAPTURES)
    started = time.monotonic()
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    lock_handle = (CACHE_ROOT / ".lock").open("w")
    try:
        fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"golden: another golden run holds {CACHE_ROOT / '.lock'}", file=sys.stderr)
        return 2

    run_root = Path(os.path.realpath(CACHE_ROOT)) / RUN_ROOT_NAME
    if args.replay:
        work_root = args.replay.expanduser().resolve()
        version = (work_root / "version.txt").read_text().strip()
        staged_cli = None
        print(f"golden: {args.mode} replaying {work_root}", flush=True)
    else:
        cli = args.cli.expanduser().resolve() if args.cli else build_cli()
        if not cli.exists():
            print(f"golden: {cli} does not exist", file=sys.stderr)
            return 2
        if run_root.exists():
            shutil.rmtree(run_root)
        run_root.mkdir(parents=True)
        staged_cli = stage_cli(cli, run_root)
        version = cli_version(staged_cli)
        (run_root / "version.txt").write_text(version + "\n")
        work_root = run_root
        print(f"golden: {args.mode} with {cli} (version {version})", flush=True)
        print(f"golden: scratch root {run_root}", flush=True)

    timings: dict[str, float] = {}
    failures: list[str] = []
    for name in names:
        context = captures.CaptureContext(
            name=name, repo_root=REPO_ROOT, cli=staged_cli, run_root=run_root,
            cache_root=CACHE_ROOT, strict=args.strict, work_root=work_root,
        )
        context.normalizer = normalize.Normalizer(run_root=str(run_root), app_version=version, strict=args.strict)
        capture_started = time.monotonic()
        try:
            if not args.replay:
                context.prepare()
                captures.CAPTURES[name].run(context)
            captures.CAPTURES[name].collect(context)
            context.finish()
        except captures.CaptureError as error:
            timings[name] = time.monotonic() - capture_started
            failures.append(f"{name}: capture failed\n{error}\n")
            print(f"[{name}] FAILED to run in {timings[name]:.1f} s", flush=True)
            continue
        timings[name] = time.monotonic() - capture_started
        problems = context.problems + portability_problems(name, context.outputs, run_root)
        if problems:
            failures.append(f"{name}: outputs are not reproducible or not portable\n" + "".join(p + "\n" for p in problems))
        destination = args.golden_dir / name
        if args.mode == "capture":
            if problems:
                print(f"[{name}] NOT captured, {len(problems)} problems in {timings[name]:.1f} s", flush=True)
                continue
            if destination.exists():
                shutil.rmtree(destination)
            for relpath, data in context.outputs.items():
                target = destination / relpath
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            print(f"[{name}] captured {len(context.outputs)} files in {timings[name]:.1f} s", flush=True)
            continue
        report = diff_capture(name, golden_files(destination), context.outputs)
        if report:
            failures.append("".join(report))
            print(f"[{name}] DIFFERS ({len(context.outputs)} files) in {timings[name]:.1f} s", flush=True)
        else:
            print(f"[{name}] matches ({len(context.outputs)} files) in {timings[name]:.1f} s", flush=True)

    total = time.monotonic() - started
    summary = {
        "mode": args.mode,
        "strict": args.strict,
        "replay": str(args.replay) if args.replay else None,
        "version": version,
        "captures": {name: round(seconds, 1) for name, seconds in timings.items()},
        "totalSeconds": round(total, 1),
        "passed": not failures,
    }
    (CACHE_ROOT / f"last-{args.mode}.json").write_text(json.dumps(summary, indent=2) + "\n")
    if failures:
        sys.stdout.write("\n" + "\n".join(failures))
    if not args.strict and normalize.PENDING_RULES:
        print(f"golden: rules waiting for a ruling were applied ({', '.join(normalize.PENDING_RULES)}), "
              "see Tests/Fixtures/golden/README.md or run with --strict", flush=True)
    print(f"golden: {args.mode} {'passed' if not failures else 'FAILED'} in {total:.1f} s "
          f"({', '.join(f'{n} {s:.1f} s' for n, s in timings.items())})", flush=True)
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
