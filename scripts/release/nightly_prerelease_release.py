#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]

VERSIONED_FILES = (
    "Lungfish.xcodeproj/project.pbxproj",
    "Sources/LungfishApp/App/AboutWindowController.swift",
    "Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist",
    "Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift",
    "Sources/LungfishCLI/Commands/PrimerCommand.swift",
    "Sources/LungfishCLI/Commands/SequenceCommand.swift",
    "Sources/LungfishCLI/LungfishCLI.swift",
    "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json",
    "Tests/LungfishCLITests/CLIRegressionTests.swift",
    "Tests/LungfishWorkflowTests/CondaManagerTests.swift",
)

AGENT_BRANCH_PREFIXES = ("codex/", "claude/")
CLAUDE_WORKTREE_PREFIX = "worktree-"
PROTECTED_BRANCHES = {"main", "master", "develop", "development"}
DEFAULT_TEST_COMMAND = "swift test"
DEFAULT_SPARKLE_RELEASE = "sparkle-beta"
PRERELEASE_PATTERN = re.compile(r"(.+)-(alpha|beta)(\d+)")


@dataclasses.dataclass(frozen=True)
class BranchCandidate:
    name: str
    ref: str
    source: str
    worktree_path: Path | None = None
    has_remote: bool = False


@dataclasses.dataclass(frozen=True)
class StashMatch:
    ref: str
    branch: str
    summary: str


class NightlyReleaseError(RuntimeError):
    pass


def is_agent_branch(branch: str) -> bool:
    if branch.startswith("origin/"):
        branch = branch.removeprefix("origin/")
    if branch in PROTECTED_BRANCHES:
        return False
    return branch.startswith(AGENT_BRANCH_PREFIXES) or branch.startswith(CLAUDE_WORKTREE_PREFIX)


def is_agent_worktree_path(path: Path, root: Path) -> bool:
    try:
        relative = path.resolve().relative_to(root.resolve())
    except ValueError:
        return False
    parts = relative.parts
    return len(parts) >= 3 and parts[0] == ".claude" and parts[1] == "worktrees"


def parse_prerelease_version(current_version: str, expected_channel: str | None = None) -> tuple[str, str, int]:
    match = PRERELEASE_PATTERN.fullmatch(current_version)
    if not match:
        raise NightlyReleaseError(f"current version is not a prerelease version: {current_version}")
    base, channel, number = match.groups()
    if expected_channel is not None and channel != expected_channel:
        raise NightlyReleaseError(f"current version is not an {expected_channel} version: {current_version}")
    return base, channel, int(number)


def next_prerelease_version(current_version: str, tags: list[str]) -> str:
    base, channel, current_number = parse_prerelease_version(current_version)
    prefix = f"{base}-{channel}"
    highest = current_number
    tag_pattern = re.compile(rf"^v{re.escape(prefix)}(\d+)$")
    for tag in tags:
        tag_match = tag_pattern.fullmatch(tag)
        if tag_match:
            highest = max(highest, int(tag_match.group(1)))
    return f"{prefix}{highest + 1}"


def previous_prerelease_tag(current_version: str, tags: list[str]) -> str:
    base, channel, current_number = parse_prerelease_version(current_version)
    prefix = f"{base}-{channel}"
    exact_tag = f"v{current_version}"
    if exact_tag in tags:
        return exact_tag

    tag_pattern = re.compile(rf"^v{re.escape(prefix)}(\d+)$")
    prior_numbers = sorted(
        int(tag_match.group(1))
        for tag in tags
        if (tag_match := tag_pattern.fullmatch(tag)) and int(tag_match.group(1)) < current_number
    )
    if not prior_numbers:
        raise NightlyReleaseError(f"no previous {channel} tag found for {current_version}")
    return f"v{prefix}{prior_numbers[-1]}"


def update_versioned_files(root: Path, old_version: str, new_version: str) -> list[str]:
    changed: list[str] = []
    for relative_path in VERSIONED_FILES:
        path = root / relative_path
        if not path.is_file():
            raise NightlyReleaseError(f"versioned file not found: {relative_path}")
        text = path.read_text(encoding="utf-8")
        if old_version not in text:
            raise NightlyReleaseError(f"{relative_path} does not contain {old_version}")
        path.write_text(text.replace(old_version, new_version), encoding="utf-8")
        changed.append(relative_path)
    return changed


def prune_rescue_archives(rescue_root: Path, retention_days: int = 2, now: float | None = None) -> list[Path]:
    if not rescue_root.exists():
        return []
    cutoff = (time.time() if now is None else now) - (retention_days * 24 * 60 * 60)
    removed: list[Path] = []
    for child in sorted(rescue_root.iterdir()):
        if child.is_dir() and child.stat().st_mtime < cutoff:
            shutil.rmtree(child)
            removed.append(child)
    return removed


def parse_agent_stashes(stash_list: str) -> list[StashMatch]:
    matches: list[StashMatch] = []
    pattern = re.compile(r"^(stash@\{\d+\}): (?:WIP on|On) ([^:]+): ?(.*)$")
    for line in stash_list.splitlines():
        match = pattern.match(line)
        if not match:
            continue
        ref, branch, summary = match.groups()
        if is_agent_branch(branch):
            matches.append(StashMatch(ref=ref, branch=branch, summary=summary))
    return matches


def run(command: list[str], cwd: Path, *, env: dict[str, str] | None = None) -> None:
    subprocess.run(command, cwd=cwd, env=env, check=True)


def output(command: list[str], cwd: Path) -> str:
    result = subprocess.run(
        command,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout


def git(root: Path, *args: str) -> None:
    run(["git", *args], cwd=root)


def git_output(root: Path, *args: str) -> str:
    return output(["git", *args], cwd=root)


def ensure_clean_main(root: Path, main_branch: str) -> None:
    current = git_output(root, "branch", "--show-current").strip()
    if current != main_branch:
        git(root, "switch", main_branch)
    status = git_output(root, "status", "--porcelain")
    if status.strip():
        raise NightlyReleaseError(
            f"{main_branch} worktree is dirty; use a dedicated clean release checkout"
        )


def ensure_rescue_root_is_ignored(root: Path, rescue_root: Path) -> None:
    relative = rescue_root.relative_to(root) if rescue_root.is_relative_to(root) else rescue_root
    result = subprocess.run(["git", "check-ignore", "-q", str(relative)], cwd=root)
    if result.returncode != 0:
        raise NightlyReleaseError(f"rescue path is not ignored by git: {relative}")


def create_lock(root: Path) -> Path:
    lock_path = root / ".build" / "nightly-prerelease-release.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        lock_path.mkdir()
    except FileExistsError as exc:
        raise NightlyReleaseError(f"nightly release lock already exists: {lock_path}") from exc
    (lock_path / "pid").write_text(f"{os.getpid()}\n", encoding="utf-8")
    return lock_path


def parse_worktrees(text: str) -> list[dict[str, str]]:
    worktrees: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in text.splitlines():
        if not line:
            if current:
                worktrees.append(current)
                current = {}
            continue
        key, _, value = line.partition(" ")
        current[key] = value
    if current:
        worktrees.append(current)
    return worktrees


def local_branches(root: Path) -> set[str]:
    text = git_output(root, "for-each-ref", "--format=%(refname:short)", "refs/heads")
    return {line.strip() for line in text.splitlines() if line.strip()}


def remote_branches(root: Path, remote: str) -> set[str]:
    text = git_output(root, "for-each-ref", "--format=%(refname:short)", f"refs/remotes/{remote}")
    branches: set[str] = set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.endswith("/HEAD"):
            continue
        if line.startswith(f"{remote}/"):
            branches.add(line.removeprefix(f"{remote}/"))
    return branches


def discover_agent_branches(root: Path, remote: str) -> list[BranchCandidate]:
    locals_ = local_branches(root)
    remotes = remote_branches(root, remote)
    by_name: dict[str, BranchCandidate] = {}

    worktree_text = git_output(root, "worktree", "list", "--porcelain")
    for item in parse_worktrees(worktree_text):
        branch_ref = item.get("branch", "")
        if not branch_ref.startswith("refs/heads/"):
            continue
        branch = branch_ref.removeprefix("refs/heads/")
        path = Path(item["worktree"])
        if is_agent_branch(branch) or is_agent_worktree_path(path, root):
            by_name[branch] = BranchCandidate(
                name=branch,
                ref=branch,
                source="worktree",
                worktree_path=path,
                has_remote=branch in remotes,
            )

    for branch in sorted(locals_):
        if is_agent_branch(branch) and branch not in by_name:
            by_name[branch] = BranchCandidate(
                name=branch,
                ref=branch,
                source="local",
                has_remote=branch in remotes,
            )

    for branch in sorted(remotes):
        if is_agent_branch(branch) and branch not in by_name:
            by_name[branch] = BranchCandidate(
                name=branch,
                ref=f"{remote}/{branch}",
                source="remote",
                has_remote=True,
            )

    return [by_name[name] for name in sorted(by_name)]


def has_unmerged_status(status: str) -> bool:
    unmerged_codes = {"DD", "AU", "UD", "UA", "DU", "AA", "UU"}
    for line in status.splitlines():
        if len(line) >= 2 and line[:2] in unmerged_codes:
            return True
    return False


def safe_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("_") or "unnamed"


def create_rescue_dir(root: Path, rescue_root: Path, release_tag: str) -> Path:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    candidate = rescue_root / release_tag
    if candidate.exists():
        candidate = rescue_root / f"{release_tag}-{timestamp}"
    candidate.mkdir(parents=True)
    metadata = {
        "releaseTag": release_tag,
        "createdAt": timestamp,
        "commit": git_output(root, "rev-parse", "HEAD").strip(),
    }
    (candidate / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    return candidate


def write_command_snapshot(root: Path, rescue_dir: Path, name: str, command: list[str]) -> None:
    path = rescue_dir / f"{name}.txt"
    try:
        path.write_text(output(command, cwd=root), encoding="utf-8")
    except subprocess.CalledProcessError as exc:
        path.write_text(exc.stdout or exc.stderr or str(exc), encoding="utf-8")


def archive_branch(root: Path, rescue_dir: Path, candidate: BranchCandidate) -> None:
    branches_dir = rescue_dir / "branches"
    branches_dir.mkdir(exist_ok=True)
    bundle = branches_dir / f"{safe_name(candidate.name)}.bundle"
    result = subprocess.run(
        ["git", "bundle", "create", str(bundle), candidate.ref],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        bundle.unlink(missing_ok=True)
        detail = (result.stderr or result.stdout or f"exit {result.returncode}").strip()
        raise NightlyReleaseError(f"failed to create rescue bundle for {candidate.name}: {detail}")


def archive_dirty_worktree(rescue_dir: Path, candidate: BranchCandidate) -> None:
    if candidate.worktree_path is None:
        return
    worktree_dir = rescue_dir / "dirty-worktrees" / safe_name(candidate.name)
    worktree_dir.mkdir(parents=True, exist_ok=True)
    path = candidate.worktree_path
    for name, command in {
        "status.txt": ["git", "status", "--porcelain=v1"],
        "unstaged.diff": ["git", "diff", "--binary"],
        "staged.diff": ["git", "diff", "--cached", "--binary"],
    }.items():
        result = subprocess.run(command, cwd=path, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        (worktree_dir / name).write_text(result.stdout + result.stderr, encoding="utf-8")

    untracked = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
        cwd=path,
        stdout=subprocess.PIPE,
        check=True,
    ).stdout.split(b"\0")
    untracked_root = worktree_dir / "untracked"
    for raw_relative in untracked:
        if not raw_relative:
            continue
        relative = Path(raw_relative.decode("utf-8", errors="surrogateescape"))
        source = path / relative
        destination = untracked_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.is_file() or source.is_symlink():
            shutil.copy2(source, destination, follow_symlinks=False)


def write_rescue_archive(root: Path, rescue_dir: Path, candidates: list[BranchCandidate]) -> None:
    snapshots = {
        "status-main": ["git", "status", "--porcelain=v1"],
        "worktrees": ["git", "worktree", "list", "--porcelain"],
        "branches": ["git", "branch", "-a", "--verbose"],
        "stashes": ["git", "stash", "list"],
        "log": ["git", "log", "--oneline", "--decorate", "--max-count=80"],
    }
    for name, command in snapshots.items():
        write_command_snapshot(root, rescue_dir, name, command)
    for candidate in candidates:
        archive_branch(root, rescue_dir, candidate)
        archive_dirty_worktree(rescue_dir, candidate)


def commit_dirty_worktrees(candidates: list[BranchCandidate]) -> None:
    for candidate in candidates:
        if candidate.worktree_path is None:
            continue
        status = output(["git", "status", "--porcelain=v1"], cwd=candidate.worktree_path)
        if has_unmerged_status(status):
            raise NightlyReleaseError(f"unresolved merge conflicts in {candidate.worktree_path}")
        if status.strip():
            run(["git", "add", "-A"], cwd=candidate.worktree_path)
            run(
                ["git", "commit", "-m", f"chore(nightly): capture {candidate.name} work before prerelease"],
                cwd=candidate.worktree_path,
            )


def merge_agent_branches(root: Path, candidates: list[BranchCandidate]) -> None:
    for candidate in candidates:
        already_merged = subprocess.run(
            ["git", "merge-base", "--is-ancestor", candidate.ref, "HEAD"],
            cwd=root,
        )
        if already_merged.returncode == 0:
            continue
        try:
            git(root, "merge", "--no-ff", "--no-edit", "-m", f"merge: nightly integrate {candidate.name}", candidate.ref)
        except subprocess.CalledProcessError as exc:
            raise NightlyReleaseError(f"merge failed for {candidate.name}; resolve conflicts before releasing") from exc


def current_version(root: Path) -> str:
    cli_file = root / "Sources" / "LungfishCLI" / "LungfishCLI.swift"
    match = re.search(r'version:\s*"([^"]+)"', cli_file.read_text(encoding="utf-8"))
    if not match:
        raise NightlyReleaseError("could not read LungfishCLI version")
    return match.group(1)


def write_release_notes(root: Path, old_version: str, new_version: str, previous_tag: str) -> Path:
    notes_dir = root / "docs" / "release-notes"
    notes_dir.mkdir(parents=True, exist_ok=True)
    notes_path = notes_dir / f"v{new_version}.md"
    if notes_path.exists():
        return notes_path
    log = git_output(root, "log", "--oneline", f"{previous_tag}..HEAD")
    commit_lines = [line.strip() for line in log.splitlines() if line.strip()]
    if not commit_lines:
        commit_lines = ["No code changes beyond the nightly release version bump."]
    bullets = "\n".join(f"- {line}" for line in commit_lines[:80])
    notes = f"""# Lungfish {new_version}

Previous release: v{old_version}

## Nightly Prerelease Release

This automated nightly prerelease integrates Codex and Claude agent worktrees
into `main`, publishes a notarized Apple Silicon DMG, and updates the Sparkle
prerelease appcast for testers.

## Included Commits

{bullets}

## Notes

- This release remains a prerelease build.
- Rescue archives for cleaned agent worktrees and branches are retained locally
  for two days under `.build/nightly-release-rescue/`.
"""
    notes_path.write_text(notes, encoding="utf-8")
    return notes_path


def prepare_release_commit(root: Path, release_tag: str, old_version: str, new_version: str, previous_tag: str) -> None:
    changed = update_versioned_files(root, old_version, new_version)
    notes_path = write_release_notes(root, old_version, new_version, previous_tag)
    git(root, "add", *changed, str(notes_path.relative_to(root)))
    git(root, "commit", "-m", f"release: {release_tag}")


def run_tests(root: Path, test_command: str) -> None:
    run(["/bin/bash", "-lc", test_command], cwd=root)


def build_release(
    root: Path,
    args: argparse.Namespace,
    release_tag: str,
    *,
    defer_remote_publish: bool = False,
) -> None:
    command = [
        "/bin/bash",
        str(args.release_script),
        "--team-id",
        args.team_id,
        "--notary-profile",
        args.notary_profile,
        "--signing-identity",
        args.signing_identity,
        "--github-release-tag",
        release_tag,
        "--sparkle-generate-appcast",
        args.sparkle_generate_appcast,
        "--sparkle-publish-release",
        args.sparkle_publish_release,
    ]
    if args.sparkle_public_ed_key:
        command.extend(["--sparkle-public-ed-key", args.sparkle_public_ed_key])
    if args.sparkle_ed_key_file:
        command.extend(["--sparkle-ed-key-file", args.sparkle_ed_key_file])
    if defer_remote_publish:
        command.append("--defer-remote-publish")
    env = os.environ.copy()
    if args.sparkle_public_ed_key:
        env["LUNGFISH_SPARKLE_PUBLIC_ED_KEY"] = args.sparkle_public_ed_key
    run(command, cwd=root, env=env)


def parse_metadata(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, sep, value = line.partition("=")
        if sep:
            values[key] = value
    return values


def release_artifact_path(root: Path, metadata: dict[str, str], key: str) -> Path:
    value = metadata.get(key, "")
    if not value:
        raise NightlyReleaseError(f"release metadata missing {key}")
    path = Path(value)
    return path if path.is_absolute() else root / path


def verify_release_artifacts(root: Path) -> dict[str, str]:
    metadata_path = root / "build" / "Release" / "release-metadata.txt"
    if not metadata_path.is_file():
        raise NightlyReleaseError("release metadata was not written")
    metadata = parse_metadata(metadata_path)
    dmg_path = release_artifact_path(root, metadata, "DMG_PATH")
    app_path = release_artifact_path(root, metadata, "release_app_path")
    expected_sha = metadata["dmg_sha256"]
    actual_sha = output(["shasum", "-a", "256", str(dmg_path)], cwd=root).split()[0]
    if actual_sha != expected_sha:
        raise NightlyReleaseError(f"DMG checksum mismatch: {actual_sha} != {expected_sha}")

    run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app_path)], cwd=root)
    run(["xcrun", "stapler", "validate", str(app_path)], cwd=root)
    run(["xcrun", "stapler", "validate", str(dmg_path)], cwd=root)
    run(["spctl", "-a", "-vv", "-t", "open", "--context", "context:primary-signature", str(dmg_path)], cwd=root)
    run(["scripts/smoke-test-release-tools.sh", str(app_path)], cwd=root)
    return metadata


def github_release_exists(root: Path, release_tag: str) -> bool:
    return subprocess.run(
        ["gh", "release", "view", release_tag],
        cwd=root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0


def publish_release(root: Path, args: argparse.Namespace, release_tag: str, metadata: dict[str, str]) -> None:
    target_commit = git_output(root, "rev-parse", "HEAD").strip()
    dmg_path = release_artifact_path(root, metadata, "DMG_PATH")
    notes_source = root / "docs" / "release-notes" / f"{release_tag}.md"

    if github_release_exists(root, release_tag):
        run(["gh", "release", "edit", release_tag, "--target", target_commit], cwd=root)
        run(["gh", "release", "upload", release_tag, str(dmg_path), "--clobber"], cwd=root)
    else:
        create_args = [
            "gh",
            "release",
            "create",
            release_tag,
            str(dmg_path),
            "--title",
            release_tag,
            "--prerelease",
            "--target",
            target_commit,
        ]
        if notes_source.is_file():
            create_args.extend(["--notes-file", str(notes_source)])
        else:
            create_args.extend(["--notes", f"Lungfish {metadata.get('version', release_tag)} prerelease."])
        run(create_args, cwd=root)

    sparkle_release = args.sparkle_publish_release
    if not sparkle_release:
        return

    appcast_path = release_artifact_path(root, metadata, "sparkle_appcast_path")
    version = metadata.get("version")
    if not version:
        raise NightlyReleaseError("release metadata missing version")
    notes_dest = appcast_path.parent / f"Lungfish-{version}-arm64.md"

    if github_release_exists(root, sparkle_release):
        run(["gh", "release", "edit", sparkle_release, "--target", target_commit], cwd=root)
    else:
        run(
            [
                "gh",
                "release",
                "create",
                sparkle_release,
                "--title",
                "Lungfish Sparkle Beta Appcast",
                "--notes",
                "Mutable Sparkle beta appcast feed for Lungfish Genome Explorer.",
                "--prerelease",
                "--target",
                target_commit,
            ],
            cwd=root,
        )

    run(["gh", "release", "upload", sparkle_release, str(appcast_path), "--clobber"], cwd=root)
    if notes_dest.is_file():
        run(["gh", "release", "upload", sparkle_release, str(notes_dest), "--clobber"], cwd=root)
    for signed_feed_asset in sorted(appcast_path.parent.glob(f"{appcast_path.name}.*")):
        if signed_feed_asset.is_file():
            run(["gh", "release", "upload", sparkle_release, str(signed_feed_asset), "--clobber"], cwd=root)
    for signed_notes_asset in sorted(notes_dest.parent.glob(f"{notes_dest.name}.*")):
        if signed_notes_asset.is_file():
            run(["gh", "release", "upload", sparkle_release, str(signed_notes_asset), "--clobber"], cwd=root)


def verify_published_release(
    root: Path,
    release_tag: str,
    sparkle_release: str,
    metadata: dict[str, str],
) -> dict[str, str]:
    release_json = output(["gh", "release", "view", release_tag, "--json", "url"], cwd=root)
    sparkle_json = output(["gh", "release", "view", sparkle_release, "--json", "url"], cwd=root)
    metadata["github_release"] = json.loads(release_json)["url"]
    metadata["sparkle_release"] = json.loads(sparkle_json)["url"]
    return metadata


def drop_agent_stashes(root: Path, rescue_dir: Path) -> None:
    stash_text = git_output(root, "stash", "list")
    matches = parse_agent_stashes(stash_text)
    if not matches:
        return
    stash_dir = rescue_dir / "stashes"
    stash_dir.mkdir(exist_ok=True)
    for match in matches:
        safe = safe_name(f"{match.ref}-{match.branch}")
        patch = subprocess.run(
            ["git", "stash", "show", "--patch", "--include-untracked", match.ref],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        (stash_dir / f"{safe}.patch").write_text(patch.stdout + patch.stderr, encoding="utf-8")
    for match in sorted(matches, key=lambda item: int(re.search(r"\d+", item.ref).group(0)), reverse=True):
        git(root, "stash", "drop", match.ref)


def cleanup_agent_refs(root: Path, remote: str, candidates: list[BranchCandidate], rescue_dir: Path) -> None:
    drop_agent_stashes(root, rescue_dir)
    for candidate in candidates:
        if candidate.worktree_path is not None and candidate.worktree_path.exists():
            git(root, "worktree", "remove", "--force", str(candidate.worktree_path))
    for candidate in candidates:
        if candidate.name in local_branches(root):
            git(root, "branch", "-D", candidate.name)
        if candidate.has_remote:
            subprocess.run(["git", "push", remote, "--delete", candidate.name], cwd=root, check=False)


def print_summary(metadata: dict[str, str], release_tag: str, rescue_dir: Path) -> None:
    print("Nightly prerelease complete:")
    print(f"  Release: {release_tag}")
    print(f"  GitHub: {metadata.get('github_release', '')}")
    print(f"  Sparkle: {metadata.get('sparkle_release', '')}")
    print(f"  DMG: {metadata.get('DMG_PATH', '')}")
    print(f"  SHA-256: {metadata.get('dmg_sha256', '')}")
    print(f"  Rescue archive: {rescue_dir}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Merge agent worktrees and publish a nightly Lungfish prerelease.")
    parser.add_argument("--repo", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--main-branch", default="main")
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--rescue-root", type=Path, default=PROJECT_ROOT / ".build" / "nightly-release-rescue")
    parser.add_argument("--rescue-retention-days", type=int, default=2)
    parser.add_argument("--test-command", default=DEFAULT_TEST_COMMAND)
    parser.add_argument("--release-script", type=Path, default=PROJECT_ROOT / "scripts" / "release" / "build-notarized-dmg.sh")
    parser.add_argument("--signing-identity", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--notary-profile", required=True)
    parser.add_argument("--sparkle-generate-appcast", required=True)
    parser.add_argument("--sparkle-publish-release", default=DEFAULT_SPARKLE_RELEASE)
    parser.add_argument("--sparkle-public-ed-key", default=os.environ.get("LUNGFISH_SPARKLE_PUBLIC_ED_KEY", ""))
    parser.add_argument("--sparkle-ed-key-file", default="")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    root = args.repo.resolve()
    rescue_root = args.rescue_root.resolve()
    lock_path: Path | None = None
    try:
        lock_path = create_lock(root)
        ensure_rescue_root_is_ignored(root, rescue_root)
        prune_rescue_archives(rescue_root, retention_days=args.rescue_retention_days)
        ensure_clean_main(root, args.main_branch)
        git(root, "fetch", "--all", "--tags", "--prune")
        git(root, "pull", "--ff-only", args.remote, args.main_branch)

        old_version = current_version(root)
        tags = git_output(root, "tag", "--list").splitlines()
        new_version = next_prerelease_version(old_version, tags)
        release_tag = f"v{new_version}"
        if release_tag in tags:
            raise NightlyReleaseError(f"release tag already exists: {release_tag}")

        candidates = discover_agent_branches(root, args.remote)
        rescue_dir = create_rescue_dir(root, rescue_root, release_tag)
        write_rescue_archive(root, rescue_dir, candidates)

        commit_dirty_worktrees(candidates)
        merge_agent_branches(root, candidates)
        prepare_release_commit(root, release_tag, old_version, new_version, previous_prerelease_tag(old_version, tags))
        run_tests(root, args.test_command)
        git(root, "tag", "-a", release_tag, "-m", f"Lungfish {release_tag}")
        build_release(root, args, release_tag, defer_remote_publish=True)
        metadata = verify_release_artifacts(root)
        git(root, "push", args.remote, args.main_branch)
        git(root, "push", args.remote, release_tag)
        publish_release(root, args, release_tag, metadata)
        metadata = verify_published_release(root, release_tag, args.sparkle_publish_release, metadata)
        cleanup_agent_refs(root, args.remote, candidates, rescue_dir)
        ensure_clean_main(root, args.main_branch)
        print_summary(metadata, release_tag, rescue_dir)
        return 0
    except (NightlyReleaseError, subprocess.CalledProcessError) as exc:
        print(f"nightly prerelease failed: {exc}", file=sys.stderr)
        return 1
    finally:
        if lock_path is not None and lock_path.exists():
            shutil.rmtree(lock_path)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
