#!/usr/bin/env python3
"""Validate the repository interfaces required by the Lungfish release skill."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


REQUIRED_FILES = (
    "scripts/release/build-notarized-dmg.sh",
    "docs/release/sparkle-updates.md",
    ".codex/agents/release-agent.md",
    "SKILLS.md",
    "scripts/tests/test_sparkle_release_packaging.py",
    "scripts/tests/test_release_smoke.py",
)

REQUIRED_FLAGS = (
    "--github-release-tag",
    "--sparkle-generate-appcast",
    "--sparkle-publish-release",
    "--sparkle-bridge-publish-release",
    "--prune-prereleases",
    "--defer-remote-publish",
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
        script_text = release_script.read_text(errors="replace")
        for flag in REQUIRED_FLAGS:
            if flag not in script_text:
                errors.append(f"Release script no longer exposes required flag: {flag}")

    if not (skill_root / "SKILL.md").is_file():
        errors.append(f"Missing skill instructions: {skill_root / 'SKILL.md'}")

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
