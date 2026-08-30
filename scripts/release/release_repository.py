#!/usr/bin/env python3
"""Resolve one selected Git remote into a redacted GitHub repository identity."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
from pathlib import Path
import re
import subprocess


REMOTE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
GITHUB_REPOSITORY = re.compile(
    r"^(?P<owner>[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/(?P<repo>[A-Za-z0-9._-]{1,100})$",
    re.ASCII,
)
HTTPS_REMOTE = re.compile(
    r"^https://github\.com/(?P<owner>[A-Za-z0-9-]+)/(?P<repo>[A-Za-z0-9._-]+?)(?:\.git)?$",
    re.ASCII | re.IGNORECASE,
)
SSH_REMOTE = re.compile(
    r"^(?:ssh://git@github\.com/|git@github\.com:)(?P<owner>[A-Za-z0-9-]+)/(?P<repo>[A-Za-z0-9._-]+?)(?:\.git)?$",
    re.ASCII | re.IGNORECASE,
)


class RepositoryIdentityError(ValueError):
    """The selected Git remote is absent, unsafe, or not a GitHub repository."""


@dataclass(frozen=True)
class RepositoryIdentity:
    remote: str
    github_repository: str
    repository_key: str


def github_repository_from_url(url: str) -> str:
    value = url.strip()
    match = HTTPS_REMOTE.fullmatch(value) or SSH_REMOTE.fullmatch(value)
    if match is None:
        raise RepositoryIdentityError(
            "selected Git remote must be an uncredentialed github.com repository"
        )
    repository = f"{match.group('owner')}/{match.group('repo')}".lower()
    parsed = GITHUB_REPOSITORY.fullmatch(repository)
    if parsed is None or set(parsed.group("repo")) == {"."}:
        raise RepositoryIdentityError("selected Git remote repository is malformed")
    return repository


def repository_identity_from_url(
    remote: str, url: str, expected_repository: str | None = None
) -> RepositoryIdentity:
    if REMOTE_NAME.fullmatch(remote) is None:
        raise RepositoryIdentityError("selected Git remote name is invalid")
    repository = github_repository_from_url(url)
    if expected_repository is not None:
        expected = GITHUB_REPOSITORY.fullmatch(expected_repository)
        if expected is None or set(expected.group("repo")) == {"."}:
            raise RepositoryIdentityError(
                "requested GitHub repository identity is malformed"
            )
        if expected_repository.lower() != repository:
            raise RepositoryIdentityError(
                "selected Git remote does not match the requested GitHub repository"
            )
    return RepositoryIdentity(
        remote=remote,
        github_repository=repository,
        repository_key=hashlib.sha256(f"github.com/{repository}".encode()).hexdigest(),
    )


def repository_identity_from_endpoints(
    remote: str,
    fetch_urls: list[str],
    push_urls: list[str],
    expected_repository: str | None = None,
) -> RepositoryIdentity:
    if len(fetch_urls) != 1 or len(push_urls) != 1:
        raise RepositoryIdentityError(
            "selected Git remote must have one fetch and one push endpoint"
        )
    fetch = repository_identity_from_url(remote, fetch_urls[0], expected_repository)
    push = repository_identity_from_url(remote, push_urls[0], expected_repository)
    if fetch.github_repository != push.github_repository:
        raise RepositoryIdentityError(
            "selected Git remote fetch and push repositories do not match"
        )
    return fetch


def _effective_urls(project_root: Path, remote: str, *, push: bool) -> list[str]:
    command = ["git", "-C", str(project_root), "remote", "get-url", "--all"]
    if push:
        command.append("--push")
    command.append(remote)
    result = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    raw = result.stdout or ""
    if result.returncode != 0 or not raw.strip() or len(raw.encode()) > 16 * 1024:
        raise RepositoryIdentityError("selected Git remote is unavailable")
    return [line.strip() for line in raw.splitlines() if line.strip()]


def resolve_repository_identity(
    project_root: Path, remote: str, expected_repository: str | None = None
) -> RepositoryIdentity:
    if REMOTE_NAME.fullmatch(remote) is None:
        raise RepositoryIdentityError("selected Git remote name is invalid")
    return repository_identity_from_endpoints(
        remote,
        _effective_urls(project_root, remote, push=False),
        _effective_urls(project_root, remote, push=True),
        expected_repository,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--remote", required=True)
    parser.add_argument("--github-repository")
    args = parser.parse_args()
    try:
        identity = resolve_repository_identity(
            args.project_root, args.remote, args.github_repository
        )
    except RepositoryIdentityError as error:
        print(f"FAIL selected Git remote: {error}")
        return 1
    print(f"repositoryKey={identity.repository_key}")
    print(f"githubRepository={identity.github_repository}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
