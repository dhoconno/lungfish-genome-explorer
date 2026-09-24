#!/usr/bin/env python3
"""shared-slider-control.sh - Every slider in LGE goes through the shared control.

Owner decision D10 (2026-09-24, docs/reports/2026-09-23-best-practices-audit/decisions.md):
every slider uses NumericSliderField / InlineNumericSliderField from
Sources/LungfishKit/NumericSliderField.swift, so each one has the same look and a numeric
field for direct entry. This fails when a bare SwiftUI `Slider(` appears anywhere else in
Sources/, or when any AppKit `NSSlider(` is constructed. Type checks such as
`view is NSSlider` are fine.

ALLOWLIST holds files the migration has not reached yet. It must only shrink, and an entry
that no longer contains a raw slider is itself an error so the list cannot go stale.

Exit codes: 0 = clean, 1 = violation or stale allowlist entry.
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCES_DIR = REPO_ROOT / "Sources"
SHARED_CONTROL = "Sources/LungfishKit/NumericSliderField.swift"
# The depth-cap lane (D9) is editing this file; the orchestrator migrates it afterwards.
ALLOWLIST = {"Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift"}

BARE_SLIDER = re.compile(r"(?<![A-Za-z0-9_])Slider\(")
NS_SLIDER = re.compile(r"(?<![A-Za-z0-9_])NSSlider\(")


def code_lines(path):
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("*") or stripped.startswith("/*"):
            continue
        yield number, stripped


def main():
    violations = []
    files_with_raw_slider = set()
    for path in sorted(SOURCES_DIR.rglob("*.swift")):
        rel = path.relative_to(REPO_ROOT).as_posix()
        for number, line in code_lines(path):
            if NS_SLIDER.search(line):
                violations.append(f"{rel}:{number}: constructs NSSlider (use NumericSliderField)")
            if rel != SHARED_CONTROL and BARE_SLIDER.search(line):
                files_with_raw_slider.add(rel)
                if rel not in ALLOWLIST:
                    violations.append(f"{rel}:{number}: raw Slider( (use NumericSliderField)")
    for rel in sorted(ALLOWLIST - files_with_raw_slider):
        violations.append(f"{rel}: allowlisted but has no raw Slider any more; remove it from ALLOWLIST")
    if violations:
        print("shared-slider-control ratchet FAILED:", file=sys.stderr)
        for violation in violations:
            print(f"  {violation}", file=sys.stderr)
        return 1
    print("shared-slider-control ratchet OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
