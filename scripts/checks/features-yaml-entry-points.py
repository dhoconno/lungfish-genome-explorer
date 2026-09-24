#!/usr/bin/env python3
"""features-yaml-entry-points.py - Verify docs/user-manual/features.yaml menu
entry points against the titles MainMenu.swift actually builds.

Background (2026-09-23 best-practices audit, FEA-16): features.yaml is the
manual pipeline's ground truth for GUI entry points, but several entries
named menu paths that do not exist ("File > Open", "Tools > Freyja Demix",
"Tools > Operations > Workflow Builder", ...). Those propagate into chapters
and screenshot recipes. This script is a local, best-effort guard: it does
not build or run the app, it only checks that every top-level menu name and
every "Menu > Item" second-level title an entry_points string opens with
appears somewhere as a literal title in MainMenu.swift (including the
dynamically generated FASTQ operation category titles).

It is intentionally conservative:
  - Only entry_points strings starting with a known top-level menu bar name
    (File, Tools, Edit, View, Sequence, Window, Help, Operations) are
    checked. CLI commands, Inspector panel sections, sidebar/context-menu
    actions, and free-text entries ("Open a VCF dataset from the sidebar")
    are left alone since they are not NSMenu items MainMenu.swift builds.
  - Only the first two path segments are checked (e.g. "Tools > Mapping"),
    not the full submenu depth, since deeper items (Search Online Databases
    submenu entries, Export > Provenance > format) are numerous and mostly
    named consistently already; the two-segment check catches the class of
    bug this audit found (a whole submenu path invented) without the far
    larger job of reproducing NSMenu's full tree structure.
  - A trailing ellipsis (single-character U+2026 or "...") and surrounding
    whitespace are ignored when comparing titles.

Usage:
    scripts/checks/features-yaml-entry-points.py            # check, print failures
    scripts/checks/features-yaml-entry-points.py --list      # print every extracted menu title, no checking

Exit codes: 0 = every checked entry point resolves, 1 = at least one does not.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FEATURES_YAML = REPO_ROOT / "docs/user-manual/features.yaml"
MAIN_MENU_SWIFT = REPO_ROOT / "Sources/LungfishApp/App/MainMenu.swift"
TOOLS_MENU_MODEL_SWIFT = REPO_ROOT / "Sources/LungfishApp/App/ToolsMenuModel.swift"

TOP_LEVEL_MENUS = {
    "File", "Edit", "View", "Sequence", "Tools", "Operations", "Window",
    "Help",
}

TITLE_PATTERN = re.compile(r'(?:withTitle|title):\s*"((?:[^"\\]|\\.)*)"')
MENU_TITLE_ARM_PATTERN = re.compile(r'return\s+"([^"]+)"')


def normalize(title: str) -> str:
    title = title.replace("\\u{2026}", "…")
    title = title.strip()
    title = title.rstrip("….")
    title = title.rstrip(":")
    return title.strip()


def extract_literal_titles(text: str) -> set[str]:
    titles = set()
    for match in TITLE_PATTERN.finditer(text):
        raw = match.group(1)
        # Skip obvious non-menu-item titles used for NSMenu(title:) container
        # names that duplicate their NSMenuItem sibling; harmless either way
        # since we only need the union of possible titles.
        titles.add(normalize(raw))
    return titles


def extract_dynamic_category_titles(text: str) -> set[str]:
    """Pull the FASTQOperationCategoryID.menuTitle switch arms - these never
    appear as string literals matched by TITLE_PATTERN because they are
    `return "..."` inside a computed property, not `title:`/`withTitle:`."""
    titles = set()
    match = re.search(r"var menuTitle: String \{(.*?)\n\s*\}\s*\n\}", text, re.DOTALL)
    if not match:
        return titles
    body = match.group(1)
    for arm_match in MENU_TITLE_ARM_PATTERN.finditer(body):
        titles.add(normalize(arm_match.group(1)))
    return titles


def load_known_titles() -> set[str]:
    titles = set()
    if MAIN_MENU_SWIFT.is_file():
        text = MAIN_MENU_SWIFT.read_text()
        titles |= extract_literal_titles(text)
    if TOOLS_MENU_MODEL_SWIFT.is_file():
        text = TOOLS_MENU_MODEL_SWIFT.read_text()
        titles |= extract_dynamic_category_titles(text)
    return titles


def extract_entry_point_strings(yaml_text: str) -> list[str]:
    # features.yaml entry_points are simple `- "..."` list items; a tiny
    # regex is enough without pulling in a YAML dependency.
    return [m.group(1) for m in re.finditer(r'^\s*-\s+"([^"]+)"', yaml_text, re.MULTILINE)]


def check_entry_point(entry: str, known_titles: set[str]) -> str | None:
    segments = [normalize(s) for s in entry.split(">")]
    if not segments or segments[0] not in TOP_LEVEL_MENUS:
        return None
    if len(segments) < 2:
        return None
    second = segments[1]
    if second not in known_titles:
        return f'"{entry}": second-level title "{second}" not found in MainMenu.swift'
    return None


def main() -> int:
    if not FEATURES_YAML.is_file():
        print(f"error: {FEATURES_YAML} not found", file=sys.stderr)
        return 1

    known_titles = load_known_titles()

    if "--list" in sys.argv:
        for title in sorted(known_titles):
            print(title)
        return 0

    yaml_text = FEATURES_YAML.read_text()
    entries = extract_entry_point_strings(yaml_text)

    failures = []
    for entry in entries:
        failure = check_entry_point(entry, known_titles)
        if failure:
            failures.append(failure)

    if failures:
        print(f"features-yaml-entry-points: {len(failures)} entry point(s) do not resolve:")
        for failure in failures:
            print(f"  - {failure}")
        print(
            "\nIf the menu really changed, update features.yaml to match "
            "MainMenu.swift's actual titles (or vice versa if this is a "
            "MainMenu.swift regression)."
        )
        return 1

    print(f"features-yaml-entry-points: {len(entries)} entry point string(s) checked, all resolve.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
