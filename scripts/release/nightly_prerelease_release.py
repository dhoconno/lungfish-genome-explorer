#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import release as release_coordinator  # noqa: E402

VERSIONED_FILES = (
    "Lungfish.xcodeproj/project.pbxproj",
    "Sources/LungfishCore/AppVersion.swift",
    "Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist",
    "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json",
    "Tests/LungfishCoreTests/AppVersionTests.swift",
)

AGENT_BRANCH_PREFIXES = ("codex/", "claude/")
CLAUDE_WORKTREE_PREFIX = "worktree-"
PROTECTED_BRANCHES = {"main", "master", "develop", "development"}
DEFAULT_PRERELEASES_TO_KEEP = 10
CALVER_PATTERN = re.compile(
    r"^v?(?P<year>\d{4})\.(?P<month>[1-9]|1[0-2])\.(?P<patch>[1-9]\d*)$"
)
LEGACY_PRERELEASE_PATTERN = re.compile(
    r"^v?(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)-(?P<channel>alpha|beta)(?P<number>\d+)$"
)


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
    return branch.startswith(AGENT_BRANCH_PREFIXES) or branch.startswith(
        CLAUDE_WORKTREE_PREFIX
    )


def is_agent_worktree_path(path: Path, root: Path) -> bool:
    try:
        relative = path.resolve().relative_to(root.resolve())
    except ValueError:
        return False
    parts = relative.parts
    return len(parts) >= 3 and parts[0] == ".claude" and parts[1] == "worktrees"


def parse_calver_tag(tag: str) -> tuple[int, int, int] | None:
    match = CALVER_PATTERN.fullmatch(tag)
    if match is None:
        return None
    year = int(match.group("year"))
    month = int(match.group("month"))
    patch = int(match.group("patch"))
    if not 1 <= month <= 12:
        return None
    return year, month, patch


def next_calver_version(version_tags: list[str], release_date: dt.date) -> str:
    parsed_versions = [
        parsed for tag in version_tags if (parsed := parse_calver_tag(tag)) is not None
    ]
    future_versions = [
        parsed
        for parsed in parsed_versions
        if parsed[:2] > (release_date.year, release_date.month)
    ]
    if future_versions:
        newest = max(future_versions)
        raise NightlyReleaseError(
            "future-dated CalVer exists relative to the release machine clock: "
            f"{newest[0]}.{newest[1]}.{newest[2]}"
        )
    patches = [
        parsed[2]
        for parsed in parsed_versions
        if parsed[:2] == (release_date.year, release_date.month)
    ]
    return f"{release_date.year}.{release_date.month}.{max(patches, default=0) + 1}"


def legacy_prerelease_sort_key(tag: str) -> tuple[int, int, int, int, int] | None:
    match = LEGACY_PRERELEASE_PATTERN.fullmatch(tag)
    if match is None:
        return None
    return (
        int(match.group("major")),
        int(match.group("minor")),
        int(match.group("patch")),
        0 if match.group("channel") == "alpha" else 1,
        int(match.group("number")),
    )


def previous_release_tag(current_version: str, tags: list[str]) -> str:
    exact_tag = f"v{current_version}"
    if exact_tag in tags:
        return exact_tag

    calver_tags = [
        (parsed, tag) for tag in tags if (parsed := parse_calver_tag(tag)) is not None
    ]
    if calver_tags:
        return max(calver_tags)[1]

    legacy_tags = [
        (parsed, tag)
        for tag in tags
        if (parsed := legacy_prerelease_sort_key(tag)) is not None
    ]
    if legacy_tags:
        return max(legacy_tags)[1]
    raise NightlyReleaseError(f"no previous versioned tag found for {current_version}")


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


def prune_rescue_archives(
    rescue_root: Path, retention_days: int = 2, now: float | None = None
) -> list[Path]:
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
    relative = (
        rescue_root.relative_to(root)
        if rescue_root.is_relative_to(root)
        else rescue_root
    )
    result = subprocess.run(["git", "check-ignore", "-q", str(relative)], cwd=root)
    if result.returncode != 0:
        raise NightlyReleaseError(f"rescue path is not ignored by git: {relative}")


def create_lock(root: Path) -> Path:
    lock_path = root / ".build" / "nightly-prerelease-release.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        lock_path.mkdir()
    except FileExistsError as exc:
        raise NightlyReleaseError(
            f"nightly release lock already exists: {lock_path}"
        ) from exc
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
    text = git_output(
        root, "for-each-ref", "--format=%(refname:short)", f"refs/remotes/{remote}"
    )
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


def select_approved_agent_branches(
    candidates: list[BranchCandidate], approved_names: list[str]
) -> list[BranchCandidate]:
    by_name = {candidate.name: candidate for candidate in candidates}
    unknown = sorted(set(approved_names) - set(by_name))
    if unknown:
        raise NightlyReleaseError(
            "approved agent branch was not discovered: " + ", ".join(unknown)
        )
    return [by_name[name] for name in approved_names]


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
    (candidate / "metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    return candidate


def write_command_snapshot(
    root: Path, rescue_dir: Path, name: str, command: list[str]
) -> None:
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
        raise NightlyReleaseError(
            f"failed to create rescue bundle for {candidate.name}: {detail}"
        )


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
        result = subprocess.run(
            command, cwd=path, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        (worktree_dir / name).write_text(
            result.stdout + result.stderr, encoding="utf-8"
        )

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


def write_rescue_archive(
    root: Path, rescue_dir: Path, candidates: list[BranchCandidate]
) -> None:
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
        status = output(
            ["git", "status", "--porcelain=v1"], cwd=candidate.worktree_path
        )
        if has_unmerged_status(status):
            raise NightlyReleaseError(
                f"unresolved merge conflicts in {candidate.worktree_path}"
            )
        if status.strip():
            run(["git", "add", "-A"], cwd=candidate.worktree_path)
            run(
                [
                    "git",
                    "commit",
                    "-m",
                    f"chore(nightly): capture {candidate.name} work before prerelease",
                ],
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
            git(
                root,
                "merge",
                "--no-ff",
                "--no-edit",
                "-m",
                f"merge: nightly integrate {candidate.name}",
                candidate.ref,
            )
        except subprocess.CalledProcessError as exc:
            raise NightlyReleaseError(
                f"merge failed for {candidate.name}; resolve conflicts before releasing"
            ) from exc


def current_version(root: Path) -> str:
    version_file = root / "Sources" / "LungfishCore" / "AppVersion.swift"
    match = re.search(
        r'public\s+static\s+let\s+short\s*=\s*"([^"]+)"',
        version_file.read_text(encoding="utf-8"),
    )
    if not match:
        raise NightlyReleaseError("could not read LungfishAppVersion.short")
    return match.group(1)


def write_release_notes(
    root: Path, old_version: str, new_version: str, previous_tag: str
) -> Path:
    notes_dir = root / "docs" / "release-notes"
    notes_path = notes_dir / f"{new_version}.md"
    if not notes_path.is_file():
        raise NightlyReleaseError(
            f"detailed release notes must be written before automation runs: {notes_path}"
        )
    notes = notes_path.read_text(encoding="utf-8")
    manifest_path = (
        root
        / "Sources"
        / "LungfishWorkflow"
        / "Resources"
        / "ManagedTools"
        / "third-party-tools-lock.json"
    )
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    dependency_set = str(manifest.get("dependencySet", "")).strip()
    required_markers = (
        f"# Lungfish {new_version}",
        "Channel: Preview",
        f"Previous versioned release: {previous_tag}",
        "Stable baseline:",
        f"Dependency set: {dependency_set}",
        "## Dependency versions",
    )
    for marker in required_markers:
        if marker not in notes:
            raise NightlyReleaseError(
                f"release notes are missing required content: {marker}"
            )
    return notes_path


def prepare_release_commit(
    root: Path, release_tag: str, old_version: str, new_version: str, previous_tag: str
) -> None:
    changed = update_versioned_files(root, old_version, new_version)
    notes_path = write_release_notes(root, old_version, new_version, previous_tag)
    git(root, "add", *changed, str(notes_path.relative_to(root)))
    git(root, "commit", "-m", f"release: {release_tag}")


def verify_prepared_release(root: Path, version: str, previous_tag: str) -> None:
    app_version_text = (root / "Sources/LungfishCore/AppVersion.swift").read_text(
        encoding="utf-8"
    )
    app_match = re.search(
        r'public\s+static\s+let\s+short\s*=\s*"([^"]+)"', app_version_text
    )
    if app_match is None or app_match.group(1) != version:
        raise NightlyReleaseError("prepared release has the wrong AppVersion.short")

    project_text = (root / "Lungfish.xcodeproj/project.pbxproj").read_text(
        encoding="utf-8"
    )
    marketing_versions = re.findall(
        r"MARKETING_VERSION\s*=\s*\"?([^;\"\s]+)\"?\s*;", project_text
    )
    if not marketing_versions or set(marketing_versions) != {version}:
        raise NightlyReleaseError(
            "prepared release has inconsistent MARKETING_VERSION entries"
        )

    help_plist = (
        root
        / "Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist"
    )
    with help_plist.open("rb") as handle:
        help_version = plistlib.load(handle).get("CFBundleShortVersionString")
    if help_version != version:
        raise NightlyReleaseError("prepared release has the wrong HelpBook version")

    manifest_path = (
        root
        / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"
    )
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("version") != version:
        raise NightlyReleaseError(
            "prepared release has the wrong manifest top-level version"
        )

    tests_text = (root / "Tests/LungfishCoreTests/AppVersionTests.swift").read_text(
        encoding="utf-8"
    )
    expected_test_literals = (f'"{version}"', f'"lungfish-cli {version}"')
    if any(literal not in tests_text for literal in expected_test_literals):
        raise NightlyReleaseError(
            "prepared release has stale AppVersion test expectations"
        )
    write_release_notes(root, version, version, previous_tag)


def prepare_or_resume_release(
    root: Path,
    release_tag: str,
    old_version: str,
    new_version: str,
    previous_tag: str,
) -> None:
    if old_version == new_version:
        verify_prepared_release(root, new_version, previous_tag)
    else:
        prepare_release_commit(
            root, release_tag, old_version, new_version, previous_tag
        )


def _github_command(*arguments: str) -> list[str]:
    repository = os.environ.get("GH_REPO", "")
    if not re.fullmatch(r"github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+", repository):
        raise NightlyReleaseError("selected GitHub repository identity is unavailable")
    return ["gh", "--repo", repository, *arguments]


def github_release_exists(root: Path, release_tag: str) -> bool:
    return (
        subprocess.run(
            _github_command("release", "view", release_tag),
            cwd=root,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode
        == 0
    )


def github_release_tags(root: Path) -> list[str]:
    raw = output(
        _github_command("release", "list", "--limit", "1000", "--json", "tagName"),
        cwd=root,
    )
    releases = json.loads(raw)
    return [
        str(release.get("tagName", ""))
        for release in releases
        if release.get("tagName")
    ]


def remote_release_tags(root: Path, remote: str) -> list[str]:
    raw = git_output(root, "ls-remote", "--tags", remote)
    tags: set[str] = set()
    for line in raw.splitlines():
        fields = line.split()
        if (
            len(fields) != 2
            or not fields[1].startswith("refs/tags/")
            or fields[1].endswith("^{}")
        ):
            continue
        tags.add(fields[1].removeprefix("refs/tags/"))
    return sorted(tags)


def ensure_release_collision_free(root: Path, remote: str, release_tag: str) -> None:
    remote_match = git_output(
        root, "ls-remote", "--tags", remote, f"refs/tags/{release_tag}"
    ).strip()
    if remote_match or github_release_exists(root, release_tag):
        raise NightlyReleaseError(
            f"release version collision for {release_tag}; fetch current tags and releases, then recompute CalVer"
        )


def prepared_release_recovery_receipt(
    root: Path, remote: str, channel: str = "preview"
) -> Path | None:
    version = current_version(root)
    if parse_calver_tag(version) is None:
        return None
    tag = f"v{version}"
    head = git_output(root, "rev-parse", "HEAD").strip()
    probe = release_coordinator.CandidateIdentity(
        receipt=root / "build/Release/unsigned-candidate-receipt.json",
        tag=tag,
        commit=head,
        version=version,
        scratch_path=Path("/"),
    )
    try:
        transaction_state = release_coordinator.tagged_publication_state(
            root, remote, channel, probe
        )
    except release_coordinator.ReleaseError as error:
        raise NightlyReleaseError(str(error)) from error
    if transaction_state == "untagged":
        return None
    if transaction_state == "complete":
        return None

    receipt_path = root / "build/Release/unsigned-candidate-receipt.json"
    try:
        receipt_info = receipt_path.lstat()
    except OSError as error:
        raise NightlyReleaseError(
            f"tagged release recovery receipt is unavailable: {receipt_path}"
        ) from error
    if (
        not stat.S_ISREG(receipt_info.st_mode)
        or stat.S_ISLNK(receipt_info.st_mode)
        or not 0 < receipt_info.st_size <= 1024 * 1024
    ):
        raise NightlyReleaseError("tagged release recovery receipt is unsafe")
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt_commit = receipt["source"]["commit"]
        release = receipt["release"]
        receipt_version = release["version"]
        receipt_channel = release["channel"]
        scratch_path = receipt["build"]["scratchPath"]
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise NightlyReleaseError(
            "tagged release recovery receipt is malformed"
        ) from error
    if (
        receipt_commit != head
        or receipt_version != version
        or receipt_channel != channel
        or not isinstance(scratch_path, str)
        or not scratch_path.startswith("/")
    ):
        raise NightlyReleaseError(
            "tagged release recovery receipt identity does not match HEAD/version/channel"
        )
    contract_path = root / "config/release-contract.json"
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        app_filename = contract["channels"][channel]["appBundleFilename"]
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise NightlyReleaseError("release contract is malformed") from error
    if not isinstance(app_filename, str) or not app_filename:
        raise NightlyReleaseError("release contract app filename is malformed")
    run(
        [
            str(root / "scripts/release/release-candidate-receipt.py"),
            "verify",
            "--app",
            str(receipt_path.parent / app_filename),
            "--receipt",
            str(receipt_path),
            "--channel",
            channel,
            "--scratch-path",
            scratch_path,
        ],
        cwd=root,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    return receipt_path


def run_common_coordinator(
    root: Path,
    args: argparse.Namespace,
    resume_receipt: Path | None = None,
) -> None:
    mode = (
        ["--resume", str(resume_receipt)]
        if resume_receipt is not None
        else ["--prepare"]
    )
    command = [
        sys.executable,
        str(args.release_coordinator),
        "preview",
        *mode,
        "--repo",
        str(root),
        "--remote",
        args.remote,
        "--main-branch",
        args.main_branch,
        "--dependency-receipt",
        str(args.dependency_receipt),
        "--signing-identity",
        args.signing_identity,
        "--team-id",
        args.team_id,
        "--notary-profile",
        args.notary_profile,
        "--sparkle-generate-appcast",
        str(args.sparkle_generate_appcast),
        "--sparkle-public-ed-key",
        args.sparkle_public_ed_key,
        "--ci-timeout-seconds",
        str(args.ci_timeout_seconds),
        "--ci-poll-seconds",
        str(args.ci_poll_seconds),
        "--prune-prereleases-keep",
        str(args.prune_prereleases_keep),
    ]
    github_repository = getattr(args, "github_repository", "")
    if github_repository:
        command.extend(["--github-repository", github_repository])
    if args.sparkle_ed_key_file:
        command.extend(["--sparkle-ed-key-file", str(args.sparkle_ed_key_file)])
    command.append(
        "--prune-prereleases" if args.prune_prereleases else "--no-prune-prereleases"
    )
    run(command, cwd=root)


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
        (stash_dir / f"{safe}.patch").write_text(
            patch.stdout + patch.stderr, encoding="utf-8"
        )
    for match in sorted(
        matches,
        key=lambda item: int(re.search(r"\d+", item.ref).group(0)),
        reverse=True,
    ):
        git(root, "stash", "drop", match.ref)


def cleanup_agent_refs(
    root: Path, remote: str, candidates: list[BranchCandidate], rescue_dir: Path
) -> None:
    for candidate in candidates:
        if candidate.worktree_path is not None and candidate.worktree_path.exists():
            status = output(
                ["git", "status", "--porcelain=v1"], cwd=candidate.worktree_path
            )
            if status.strip():
                print(
                    f"Preserving agent worktree changed during release: {candidate.worktree_path}",
                    file=sys.stderr,
                )
                continue
            merged = (
                subprocess.run(
                    ["git", "merge-base", "--is-ancestor", candidate.name, "HEAD"],
                    cwd=root,
                    check=False,
                ).returncode
                == 0
            )
            if not merged:
                print(
                    f"Preserving agent worktree whose tip is not merged: {candidate.worktree_path}",
                    file=sys.stderr,
                )
                continue
            git(root, "worktree", "remove", str(candidate.worktree_path))
    for candidate in candidates:
        if candidate.name in local_branches(root):
            subprocess.run(
                ["git", "branch", "-d", candidate.name], cwd=root, check=False
            )


def print_summary(release_tag: str, rescue_dir: Path) -> None:
    print("Nightly preview release complete:")
    print(f"  Release: {release_tag}")
    print(f"  Rescue archive: {rescue_dir}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Merge agent worktrees and publish a nightly Lungfish preview release."
    )
    parser.add_argument("--repo", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--main-branch", default="main")
    parser.add_argument("--remote", default="origin")
    parser.add_argument(
        "--rescue-root",
        type=Path,
        default=PROJECT_ROOT / ".build" / "nightly-release-rescue",
    )
    parser.add_argument("--rescue-retention-days", type=int, default=2)
    parser.add_argument(
        "--approved-agent-branch",
        action="append",
        default=[],
        help="Agent branch already classified as release work; repeat for each approved branch",
    )
    parser.add_argument(
        "--release-coordinator",
        type=Path,
        default=PROJECT_ROOT / "scripts" / "release" / "release.py",
    )
    parser.add_argument("--signing-identity", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--notary-profile", required=True)
    parser.add_argument("--sparkle-generate-appcast", required=True)
    parser.add_argument(
        "--dependency-receipt",
        type=Path,
        default=Path.home() / ".lungfish-verify/dependency-receipt.json",
    )
    parser.add_argument("--ci-timeout-seconds", type=int, default=6 * 60 * 60)
    parser.add_argument("--ci-poll-seconds", type=int, default=30)
    parser.add_argument(
        "--sparkle-public-ed-key",
        default=os.environ.get("LUNGFISH_SPARKLE_PUBLIC_ED_KEY", ""),
    )
    parser.add_argument("--sparkle-ed-key-file", default="")
    prune_group = parser.add_mutually_exclusive_group()
    prune_group.add_argument(
        "--prune-prereleases",
        dest="prune_prereleases",
        action="store_true",
        default=True,
    )
    prune_group.add_argument(
        "--no-prune-prereleases", dest="prune_prereleases", action="store_false"
    )
    parser.add_argument(
        "--prune-prereleases-keep", type=int, default=DEFAULT_PRERELEASES_TO_KEEP
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    root = args.repo.resolve()
    rescue_root = args.rescue_root.resolve()
    lock_path: Path | None = None
    try:
        try:
            repository = release_coordinator.resolve_repository_identity(
                root, args.remote
            )
        except release_coordinator.RepositoryIdentityError as error:
            raise NightlyReleaseError(str(error)) from error
        args.github_repository = repository.github_repository
        os.environ.pop("GH_HOST", None)
        os.environ["GH_REPO"] = f"github.com/{repository.github_repository}"
        lock_path = create_lock(root)
        ensure_rescue_root_is_ignored(root, rescue_root)
        prune_rescue_archives(rescue_root, retention_days=args.rescue_retention_days)
        ensure_clean_main(root, args.main_branch)
        git(root, "fetch", "--all", "--tags", "--prune")
        git(root, "pull", "--ff-only", args.remote, args.main_branch)

        old_version = current_version(root)
        recovery_receipt = prepared_release_recovery_receipt(
            root, args.remote, channel="preview"
        )
        if recovery_receipt is not None:
            release_tag = f"v{old_version}"
            rescue_dir = create_rescue_dir(root, rescue_root, release_tag)
            write_rescue_archive(root, rescue_dir, [])
            run_common_coordinator(root, args, resume_receipt=recovery_receipt)
            ensure_clean_main(root, args.main_branch)
            print_summary(release_tag, rescue_dir)
            return 0
        tags = git_output(root, "tag", "--list").splitlines()
        release_versions = sorted(
            set(remote_release_tags(root, args.remote)) | set(github_release_tags(root))
        )
        release_date = dt.date.today()
        new_version = next_calver_version(release_versions, release_date)
        release_tag = f"v{new_version}"
        ensure_release_collision_free(root, args.remote, release_tag)

        discovered_candidates = discover_agent_branches(root, args.remote)
        candidates = select_approved_agent_branches(
            discovered_candidates, args.approved_agent_branch
        )
        rescue_dir = create_rescue_dir(root, rescue_root, release_tag)
        write_rescue_archive(root, rescue_dir, candidates)

        commit_dirty_worktrees(candidates)
        merge_agent_branches(root, candidates)
        previous_tag = previous_release_tag(old_version, tags)
        prepare_or_resume_release(
            root, release_tag, old_version, new_version, previous_tag
        )
        run_common_coordinator(root, args)
        cleanup_agent_refs(root, args.remote, candidates, rescue_dir)
        ensure_clean_main(root, args.main_branch)
        print_summary(release_tag, rescue_dir)
        return 0
    except (NightlyReleaseError, subprocess.CalledProcessError) as exc:
        print(f"nightly preview release failed: {exc}", file=sys.stderr)
        return 1
    finally:
        if lock_path is not None and lock_path.exists():
            shutil.rmtree(lock_path)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
