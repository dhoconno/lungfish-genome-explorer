#!/usr/bin/env python3
"""Validate the repository interfaces required by the Lungfish release skill."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys


REQUIRED_FILES = (
    "scripts/release/build-notarized-dmg.sh",
    "scripts/release/check-sparkle-build-number.py",
    "scripts/build-app.sh",
    "docs/release/sparkle-updates.md",
    ".codex/agents/release-agent.md",
    "SKILLS.md",
    "scripts/tests/test_sparkle_release_packaging.py",
    "scripts/tests/test_release_smoke.py",
    "scripts/full-suite-gate.sh",
    "scripts/testing/run-macos-xcui.sh",
    "scripts/tests/test_full_suite_gate_tiers.py",
)

REQUIRED_GATE_MARKERS = (
    "--tier",
    "smoke)",
    "unit)",
    "integration)",
    "conformance)",
    "full)",
)

REQUIRED_FLAGS = (
    "--github-release-tag",
    "--recover-existing-release",
    "--sparkle-generate-appcast",
    "--sparkle-publish-release",
    "--sparkle-bridge-publish-release",
    "--sparkle-bridge-appcast-filename",
    "--channel",
    "--prune-prereleases",
    "--prune-prereleases-keep",
    "--defer-remote-publish",
)

REQUIRED_SKILL_MARKERS = (
    "YYYY.M.PATCH",
    "docs/release-notes/<version>.md",
    "Git tags and GitHub releases",
    "--channel preview",
    "--channel stable",
    "Included preview releases",
    "--tier unit",
    "--tier integration",
    "--tier full",
    "--tier conformance --require-tools",
    "run-macos-xcui.sh",  # named as an attended diagnostic, not a gate
    "build-app.sh --debug",  # debug test builds are ad-hoc signed and never released
    "com.lungfish.browser.debug",
)

REQUIRED_DEBUG_MARKERS = (
    "build/Debug/Lungfish Debug.app",
    "Lungfish Genome Explorer Debug",
    "ad-hoc",
    "self-contained",
)

STALE_DEBUG_MARKERS = (
    "build/Debug/Lungfish.app",
    "NOT self-contained",
    "build is unsigned and for local testing only",
)

CONTRADICTORY_DEBUG_PATTERNS = (
    (
        "claims the Debug app has no signature",
        re.compile(
            r"(?:\bdebug(?:\s+(?:app|build|artifact)s?)?\b.{0,60}(?<!distribution[- ])\bunsigned\b|"
            r"(?<!distribution[- ])\bunsigned\b.{0,60}\bdebug(?:\s+(?:app|build|artifact)s?)?\b)",
            re.IGNORECASE,
        ),
    ),
    (
        "claims the Debug app is not ad-hoc signed",
        re.compile(
            r"(?:\bdebug(?:\s+(?:app|build|artifact)s?)?\b.{0,60}\bnot\s+ad[ -]?hoc(?:\s+signed)?\b|"
            r"\b(?:not\s+ad[ -]?hoc(?:\s+signed)?|ad[ -]?hoc\s+signing\s+is\s+not\s+used)\b"
            r".{0,60}\bdebug(?:\s+(?:app|build|artifact)s?)?\b)",
            re.IGNORECASE,
        ),
    ),
    (
        "claims the Debug app is not self-contained",
        re.compile(
            r"(?:\bdebug(?:\s+(?:app|build|artifact)s?)?\b.{0,60}\bnot\s+self[ -]?contained\b|"
            r"\bnot\s+self[ -]?contained\b.{0,60}\bdebug(?:\s+(?:app|build|artifact)s?)?\b)",
            re.IGNORECASE,
        ),
    ),
    (
        "claims the Debug app depends on the checkout",
        re.compile(
            r"(?:\bdebug\b.{0,100}\b(?:checkout[ -]dependent|depends?\s+on\b.{0,30}\bcheckout|"
            r"requires?\b.{0,40}\b(?:checkout|(?:compiling\s+)?\.build)\b)|"
            r"\b(?:checkout[ -]dependent|depends?\s+on\b.{0,30}\bcheckout)\b.{0,60}\bdebug\b)",
            re.IGNORECASE | re.DOTALL,
        ),
    ),
    (
        "names the obsolete Debug wrapper",
        re.compile(
            r"(?:\bbuild/debug/lungfish\.app\b|\bdebug\s+wrapper\s+(?:is|:)\s*[`\"']?lungfish\.app\b)",
            re.IGNORECASE,
        ),
    ),
    (
        "uses the short bundle name as the Debug display name",
        re.compile(
            r"\bdebug\b.{0,60}\b(?:display\s+name\s+(?:is|of|:)|is\s+(?:displayed|shown)\s+as)\s*"
            r"[`\"']?lungfish\s+debug\b",
            re.IGNORECASE,
        ),
    ),
)

SECRET_PATTERNS = (
    re.compile(r"gh[pousr]_[A-Za-z0-9_]{20,}"),
    re.compile(r"(?i)(?:token|password|private[_ -]?key)\s*[:=]\s*['\"]?[A-Za-z0-9+/=_-]{24,}"),
    re.compile(r"-----BEGIN (?:OPENSSH|RSA|EC|PRIVATE) PRIVATE KEY-----"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path)
    parser.add_argument("--skill-root", type=Path)
    return parser.parse_args()


def validate_debug_semantics(contents: str, source: str, errors: list[str]) -> None:
    for description, pattern in CONTRADICTORY_DEBUG_PATTERNS:
        if pattern.search(contents):
            errors.append(f"{source} contains contradictory Debug guidance: {description}")


def main() -> int:
    args = parse_args()
    default_skill = Path(__file__).resolve().parents[1]
    skill_root = (args.skill_root or default_skill).resolve()
    repo_root = (args.repo_root or default_skill.parents[2]).resolve()
    errors: list[str] = []

    for relative in REQUIRED_FILES:
        if not (repo_root / relative).is_file():
            errors.append(f"Missing required repository file: {relative}")

    release_script = repo_root / REQUIRED_FILES[0]
    if release_script.is_file():
        result = subprocess.run(
            ["bash", str(release_script), "--help"],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            errors.append(
                "Release script help failed: "
                + (result.stderr.strip() or f"exit {result.returncode}")
            )
        script_text = result.stdout + result.stderr
        for flag in REQUIRED_FLAGS:
            if flag not in script_text:
                errors.append(f"Release script no longer exposes required flag: {flag}")

    gate_script = repo_root / "scripts/full-suite-gate.sh"
    if gate_script.is_file():
        gate_text = gate_script.read_text(errors="replace")
        for marker in REQUIRED_GATE_MARKERS:
            if marker not in gate_text:
                errors.append(
                    f"full-suite-gate.sh no longer exposes required tier marker: {marker}"
                )

    skill_file = skill_root / "SKILL.md"
    if not skill_file.is_file():
        errors.append(f"Missing skill instructions: {skill_file}")
    else:
        skill_text = skill_file.read_text(errors="replace")
        for marker in REQUIRED_SKILL_MARKERS:
            if marker not in skill_text:
                errors.append(f"Release skill is missing required CalVer policy: {marker}")

        for marker in REQUIRED_DEBUG_MARKERS:
            if marker not in skill_text:
                errors.append(f"Release skill is missing current Debug guidance: {marker}")
        for marker in STALE_DEBUG_MARKERS:
            if marker in skill_text:
                errors.append(f"Release skill contains stale Debug guidance: {marker}")
        validate_debug_semantics(skill_text, "Release skill", errors)

    catalog_file = repo_root / "SKILLS.md"
    if catalog_file.is_file():
        catalog_text = catalog_file.read_text(errors="replace")
        for marker in REQUIRED_DEBUG_MARKERS:
            if marker not in catalog_text:
                errors.append(f"SKILLS.md is missing current Debug guidance: {marker}")
        for marker in STALE_DEBUG_MARKERS:
            if marker in catalog_text:
                errors.append(f"SKILLS.md contains stale Debug guidance: {marker}")
        validate_debug_semantics(catalog_text, "SKILLS.md", errors)

    for path in skill_root.rglob("*") if skill_root.is_dir() else ():
        if not path.is_file() or path.suffix in {".pyc", ".png", ".jpg"}:
            continue
        contents = path.read_text(errors="replace")
        if any(pattern.search(contents) for pattern in SECRET_PATTERNS):
            errors.append(f"Secret-like content found in skill file: {path.relative_to(skill_root)}")

    if errors:
        print("Lungfish release skill validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"Lungfish release skill is compatible with {repo_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
