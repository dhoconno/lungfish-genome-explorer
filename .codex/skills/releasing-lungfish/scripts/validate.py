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
    "docs/release/sparkle-updates.md",
    ".codex/agents/release-agent.md",
    "SKILLS.md",
    "scripts/tests/test_sparkle_release_packaging.py",
    "scripts/tests/test_release_smoke.py",
)

REQUIRED_FLAGS = (
    "--github-release-tag",
    "--recover-existing-release",
    "--sparkle-generate-appcast",
    "--sparkle-publish-release",
    "--sparkle-bridge-publish-release",
    "--sparkle-bridge-appcast-filename",
    "--prune-prereleases",
    "--prune-prereleases-keep",
    "--defer-remote-publish",
)

REQUIRED_SKILL_MARKERS = (
    "YYYY.M.PATCH",
    "docs/release-notes/<version>.md",
    "Git tags and GitHub releases",
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

    skill_file = skill_root / "SKILL.md"
    if not skill_file.is_file():
        errors.append(f"Missing skill instructions: {skill_file}")
    else:
        skill_text = skill_file.read_text(errors="replace")
        for marker in REQUIRED_SKILL_MARKERS:
            if marker not in skill_text:
                errors.append(f"Release skill is missing required CalVer policy: {marker}")

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
