#!/usr/bin/env python3
"""unchecked-operation-start.sh - Ratchet on deprecated OperationCenter.start(...) calls
that carry a bundle target.

Background (2026-09-23 best-practices audit, ARC-04 / FEA-07): OperationCenter.start(...)
returns a plain UUID even when the requested bundle lock is refused, and every existing
caller that passed targetBundleURL/additionalLockedBundleURLs had to hand-roll its own
pre-check (canStartOperation) or post-check (state == .running / .isActive) to notice a
refusal before mutating the bundle or launching a subprocess. OperationCenter.begin(...)
replaces this: it returns an OperationStartResult the caller must switch on, so a refusal
cannot be silently ignored. start(...) is now @available(*, deprecated) precisely for the
targetBundleURL / additionalLockedBundleURLs overload.

This script counts call sites that still invoke the deprecated start(...) with a bundle
target. That count must never rise: new bundle-mutating callers must use begin(...)
instead. Existing callers may remain on start(...) only because they already carry a
correct pre-check or post-check (verified by hand during the P1-A package); migrating them
to begin(...) is encouraged but not required by this ratchet.

Usage:
    scripts/ratchets/unchecked-operation-start.sh              # check against the recorded baseline
    scripts/ratchets/unchecked-operation-start.sh --print       # print each call site and the count, no pass/fail
    scripts/ratchets/unchecked-operation-start.sh --update      # rewrite the recorded baseline to the current count
                                                                  (only for a deliberate, reviewed increase)

Exit codes: 0 = at or under baseline, 1 = over baseline (a new unchecked caller was
added, or an existing one was migrated backwards from begin to start).
"""
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCES_DIR = REPO_ROOT / "Sources"
BASELINE_FILE = Path(__file__).resolve().with_suffix(".baseline")


def find_call_sites():
    try:
        listed = subprocess.check_output(
            ["rg", "-l", r"\.start\(", "Sources"], cwd=REPO_ROOT, text=True
        )
    except subprocess.CalledProcessError as exc:
        if exc.returncode == 1:
            return []  # rg found no matches at all
        raise
    files = [REPO_ROOT / line for line in listed.splitlines() if line]

    hits = []
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in re.finditer(r"\.start\(", text):
            open_paren = match.end() - 1
            depth = 0
            j = open_paren
            while j < len(text):
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            call_text = text[open_paren : j + 1]
            if "targetBundleURL:" not in call_text and "additionalLockedBundleURLs:" not in call_text:
                continue
            # Skip the declaration site itself (OperationCenter.swift's `func start(`)
            # and DownloadCenter/other unrelated start(...) declarations.
            preceding = text[max(0, match.start() - 200) : match.start()]
            if "func start(" in preceding:
                continue
            line_no = text[: match.start()].count("\n") + 1
            rel_path = path.relative_to(REPO_ROOT)
            hits.append(f"{rel_path}:{line_no}")
    return sorted(hits)


def read_baseline():
    if not BASELINE_FILE.exists():
        return None
    content = BASELINE_FILE.read_text(encoding="utf-8").strip()
    if not content:
        return None
    try:
        return int(content.splitlines()[0])
    except ValueError:
        return None


def main(argv):
    hits = find_call_sites()
    count = len(hits)

    if "--print" in argv:
        for hit in hits:
            print(hit)
        print(f"TOTAL {count}")
        return 0

    if "--update" in argv:
        BASELINE_FILE.write_text(f"{count}\n", encoding="utf-8")
        print(f"Updated baseline to {count} unchecked OperationCenter.start(...) call sites.")
        return 0

    baseline = read_baseline()
    if baseline is None:
        print(
            f"unchecked-operation-start: no baseline recorded at {BASELINE_FILE}. "
            f"Run with --update to record the current count ({count}).",
            file=sys.stderr,
        )
        return 1

    if count > baseline:
        print(
            f"unchecked-operation-start: {count} call sites still pass targetBundleURL/"
            f"additionalLockedBundleURLs to the deprecated OperationCenter.start(...), "
            f"up from the recorded baseline of {baseline}.",
            file=sys.stderr,
        )
        print(
            "New bundle-mutating callers must use OperationCenter.begin(...) instead, "
            "whose OperationStartResult the caller must switch on before launching a "
            "transport/subprocess or mutating the bundle. See ARC-04 / FEA-07 in "
            "docs/reports/2026-09-23-best-practices-audit/.",
            file=sys.stderr,
        )
        print("Offending call sites:", file=sys.stderr)
        for hit in hits:
            print(f"  {hit}", file=sys.stderr)
        return 1

    if count < baseline:
        print(
            f"unchecked-operation-start: {count} call sites, down from the recorded "
            f"baseline of {baseline}. Run with --update to lower the baseline."
        )
    else:
        print(f"unchecked-operation-start: {count} call sites, at the recorded baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
