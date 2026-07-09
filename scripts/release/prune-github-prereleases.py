#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable


PROJECT_ROOT = Path(__file__).resolve().parents[2]
PRERELEASE_TAG_PATTERN = re.compile(r"^v(?P<base>\d+\.\d+\.\d+)-(?P<channel>alpha|beta)(?P<number>\d+)$")
SPARKLE_NOTE_PATTERN = re.compile(
    r"^Lungfish-(?P<base>\d+\.\d+\.\d+)-(?P<channel>alpha|beta)(?P<number>\d+)-arm64\.md$"
)
PROTECTED_RELEASE_TAGS = frozenset({"sparkle-beta", "sparkle-alpha"})


@dataclasses.dataclass(frozen=True, order=True)
class PrereleaseVersion:
    base: str
    channel: str
    number: int
    tag: str


@dataclasses.dataclass
class PrunePlan:
    current_tag: str
    keep: int
    sparkle_release: str
    cleanup_tags: bool
    release_tags: list[str]
    sparkle_note_assets: list[str]
    protected_release_tags: list[str]
    skipped_note_assets: list[str]
    skipped_release_tags: list[str] = dataclasses.field(default_factory=list)

    def to_json(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


class PruneError(RuntimeError):
    pass


def parse_prerelease_tag(tag: str) -> PrereleaseVersion | None:
    match = PRERELEASE_TAG_PATTERN.fullmatch(tag)
    if not match:
        return None
    return PrereleaseVersion(
        base=match.group("base"),
        channel=match.group("channel"),
        number=int(match.group("number")),
        tag=tag,
    )


def release_note_path(notes_root: Path, tag: str) -> Path:
    return notes_root / f"{tag}.md"


def asset_name(asset: dict[str, Any] | str) -> str:
    if isinstance(asset, str):
        return asset
    return str(asset.get("name", ""))


def has_committed_release_note(notes_root: Path, tag: str) -> bool:
    return release_note_path(notes_root, tag).is_file()


def matching_prerelease_versions(
    releases: list[dict[str, Any]],
    *,
    current: PrereleaseVersion,
) -> list[PrereleaseVersion]:
    versions: list[PrereleaseVersion] = []
    for release in releases:
        tag = str(release.get("tagName", ""))
        if tag in PROTECTED_RELEASE_TAGS:
            continue
        if not release.get("isPrerelease", False):
            continue
        version = parse_prerelease_tag(tag)
        if version is None:
            continue
        if version.base == current.base and version.channel == current.channel:
            versions.append(version)
    return sorted(versions, reverse=True)


def build_prune_plan(
    releases: list[dict[str, Any]],
    *,
    sparkle_assets: list[dict[str, Any] | str],
    current_tag: str,
    keep: int,
    notes_root: Path,
    sparkle_release: str = "sparkle-beta",
    prune_sparkle_notes: bool = True,
) -> PrunePlan:
    if keep < 1:
        raise PruneError("--keep must be at least 1")
    current = parse_prerelease_tag(current_tag)
    if current is None:
        raise PruneError(f"current tag is not a supported prerelease tag: {current_tag}")

    versions = matching_prerelease_versions(releases, current=current)
    kept_tags = {version.tag for version in versions[:keep]}
    kept_tags.add(current_tag)

    release_tags: list[str] = []
    skipped_release_tags: list[str] = []
    existing_tags = {str(release.get("tagName", "")) for release in releases}
    for version in sorted(versions, key=lambda item: item.number):
        if version.tag in kept_tags:
            continue
        if has_committed_release_note(notes_root, version.tag):
            release_tags.append(version.tag)
        else:
            skipped_release_tags.append(version.tag)

    sparkle_note_assets: list[str] = []
    skipped_note_assets: list[str] = []
    if prune_sparkle_notes:
        for asset in sparkle_assets:
            name = asset_name(asset)
            match = SPARKLE_NOTE_PATTERN.fullmatch(name)
            if not match:
                continue
            tag = f"v{match.group('base')}-{match.group('channel')}{match.group('number')}"
            version = parse_prerelease_tag(tag)
            if version is None:
                continue
            if version.base != current.base or version.channel != current.channel:
                continue
            if tag in kept_tags or tag == current_tag:
                continue
            if tag not in existing_tags or not has_committed_release_note(notes_root, tag):
                skipped_note_assets.append(name)
                continue
            sparkle_note_assets.append(name)

    protected = sorted(PROTECTED_RELEASE_TAGS | {current_tag, sparkle_release})
    return PrunePlan(
        current_tag=current_tag,
        keep=keep,
        sparkle_release=sparkle_release,
        cleanup_tags=False,
        release_tags=release_tags,
        sparkle_note_assets=sparkle_note_assets,
        protected_release_tags=protected,
        skipped_note_assets=skipped_note_assets,
        skipped_release_tags=skipped_release_tags,
    )


def append_repo(command: list[str], repo: str) -> list[str]:
    if repo:
        return [*command, "--repo", repo]
    return command


def default_run_command(command: list[str]) -> None:
    subprocess.run(command, check=True)


def apply_plan(
    plan: PrunePlan,
    *,
    repo: str = "",
    run_command: Callable[[list[str]], None] = default_run_command,
) -> None:
    for tag in plan.release_tags:
        run_command(append_repo(["gh", "release", "delete", tag, "--yes"], repo))
    for asset in plan.sparkle_note_assets:
        run_command(append_repo(["gh", "release", "delete-asset", plan.sparkle_release, asset, "--yes"], repo))


def gh_json(args: list[str], *, repo: str) -> Any:
    command = ["gh", *args]
    if repo:
        command.extend(["--repo", repo])
    result = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return json.loads(result.stdout)


def fetch_releases(*, repo: str, limit: int) -> list[dict[str, Any]]:
    return gh_json(
        ["release", "list", "--limit", str(limit), "--json", "tagName,isPrerelease,isDraft,createdAt"],
        repo=repo,
    )


def fetch_sparkle_assets(*, repo: str, sparkle_release: str) -> list[dict[str, Any]]:
    release = gh_json(["release", "view", sparkle_release, "--json", "assets"], repo=repo)
    return list(release.get("assets", []))


def print_plan(plan: PrunePlan, *, dry_run: bool) -> None:
    mode = "dry run" if dry_run else "apply"
    print(f"GitHub prerelease retention plan ({mode}):")
    print(f"  current tag: {plan.current_tag}")
    print(f"  keep newest: {plan.keep}")
    print(f"  preserve git tags: {not plan.cleanup_tags}")
    print(f"  release records to delete: {len(plan.release_tags)}")
    for tag in plan.release_tags:
        print(f"    {tag}")
    if plan.skipped_release_tags:
        print("  release records kept because committed release notes were missing:")
        for tag in plan.skipped_release_tags:
            print(f"    {tag}")
    print(f"  Sparkle note assets to delete from {plan.sparkle_release}: {len(plan.sparkle_note_assets)}")
    for asset in plan.sparkle_note_assets:
        print(f"    {asset}")
    if plan.skipped_note_assets:
        print("  Sparkle note assets kept because preservation checks failed:")
        for asset in plan.skipped_note_assets:
            print(f"    {asset}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Prune old Lungfish prerelease GitHub Release records while preserving git tags and release notes."
    )
    parser.add_argument("--repo", default="")
    parser.add_argument("--current-tag", required=True)
    parser.add_argument("--keep", type=int, default=10)
    parser.add_argument("--sparkle-release", default="sparkle-beta")
    parser.add_argument("--notes-root", type=Path, default=PROJECT_ROOT / "docs" / "release-notes")
    parser.add_argument("--limit", type=int, default=200)
    parser.add_argument("--report-path", type=Path, default=None)
    parser.add_argument("--apply", action="store_true", help="Delete the planned GitHub release records and assets.")
    parser.add_argument("--dry-run", action="store_true", help="Print the plan without deleting anything.")
    parser.add_argument(
        "--no-prune-sparkle-notes",
        action="store_true",
        help="Keep old release-note assets on the mutable Sparkle release.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    dry_run = not args.apply or args.dry_run
    try:
        releases = fetch_releases(repo=args.repo, limit=args.limit)
        sparkle_assets = fetch_sparkle_assets(repo=args.repo, sparkle_release=args.sparkle_release)
        plan = build_prune_plan(
            releases,
            sparkle_assets=sparkle_assets,
            current_tag=args.current_tag,
            keep=args.keep,
            notes_root=args.notes_root,
            sparkle_release=args.sparkle_release,
            prune_sparkle_notes=not args.no_prune_sparkle_notes,
        )
        print_plan(plan, dry_run=dry_run)
        if args.report_path is not None:
            args.report_path.parent.mkdir(parents=True, exist_ok=True)
            args.report_path.write_text(json.dumps(plan.to_json(), indent=2) + "\n", encoding="utf-8")
        if not dry_run:
            apply_plan(plan, repo=args.repo)
        return 0
    except (PruneError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"prerelease pruning failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
