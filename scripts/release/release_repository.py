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
    r"^(?P<owner>[A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))/(?P<repo>[A-Za-z0-9._-]+)$"
)
HTTPS_REMOTE = re.compile(
    r"^https://github\.com/(?P<owner>[A-Za-z0-9-]+)/(?P<repo>[A-Za-z0-9._-]+?)(?:\.git)?$"
)
SSH_REMOTE = re.compile(
    r"^(?:ssh://git@github\.com/|git@github\.com:)(?P<owner>[A-Za-z0-9-]+)/(?P<repo>[A-Za-z0-9._-]+?)(?:\.git)?$"
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
    repository = f"{match.group('owner')}/{match.group('repo')}"
    if GITHUB_REPOSITORY.fullmatch(repository) is None:
        raise RepositoryIdentityError("selected Git remote repository is malformed")
    return repository


def repository_identity_from_url(
    remote: str, url: str, expected_repository: str | None = None
) -> RepositoryIdentity:
    if REMOTE_NAME.fullmatch(remote) is None:
        raise RepositoryIdentityError("selected Git remote name is invalid")
    repository = github_repository_from_url(url)
    if expected_repository is not None and expected_repository != repository:
        raise RepositoryIdentityError(
            "selected Git remote does not match the requested GitHub repository"
        )
    return RepositoryIdentity(
        remote=remote,
        github_repository=repository,
        repository_key=hashlib.sha256(url.strip().encode()).hexdigest(),
    )


def resolve_repository_identity(
    project_root: Path, remote: str, expected_repository: str | None = None
) -> RepositoryIdentity:
    if REMOTE_NAME.fullmatch(remote) is None:
        raise RepositoryIdentityError("selected Git remote name is invalid")
    result = subprocess.run(
        ["git", "-C", str(project_root), "config", "--get", f"remote.{remote}.url"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise RepositoryIdentityError("selected Git remote is unavailable")
    return repository_identity_from_url(remote, result.stdout, expected_repository)


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
