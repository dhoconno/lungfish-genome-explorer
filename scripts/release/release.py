#!/usr/bin/env python3
"""Coordinate one receipt-bound Lungfish release transaction."""

from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
from typing import Any, Protocol


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parents[1]
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from release_contract import load_contract  # noqa: E402
from release_repository import (  # noqa: E402
    RepositoryIdentity,
    RepositoryIdentityError,
    repository_identity_from_endpoints,
    resolve_repository_identity,
)


MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_METADATA_BYTES = 128 * 1024
CALVER = re.compile(r"^[1-9]\d{3}\.(?:[1-9]|1[0-2])\.[1-9]\d*$")
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")
HEX_COMMIT = re.compile(r"^[0-9a-f]{40}$")
PUBLIC_SPARKLE_KEY = "FtnZIDTqGTwkglQR0z8iSgVvxvT26a05QB3cI4xQw/c="


class ReleaseError(RuntimeError):
    pass


@dataclass(frozen=True)
class SourceGate:
    tier: str
    require_tools: bool


@dataclass(frozen=True)
class ReleasePlan:
    focused_release_tests: tuple[str, ...]
    source_gates: tuple[SourceGate, ...]
    requires_dependency_receipt: bool = True


@dataclass(frozen=True)
class ReleaseRequest:
    root: Path
    channel: str
    mode: str
    receipt: Path
    remote: str
    main_branch: str
    signing_identity: str
    team_id: str
    notary_profile: str
    sparkle_generate_appcast: Path
    sparkle_ed_key_file: Path | None
    dependency_receipt: Path
    release_dir: Path
    ci_timeout_seconds: int
    ci_poll_seconds: int
    prune_prereleases: bool
    prune_prereleases_keep: int
    sparkle_public_ed_key: str = PUBLIC_SPARKLE_KEY
    github_repository: str = ""


@dataclass(frozen=True)
class CandidateIdentity:
    receipt: Path
    tag: str
    commit: str
    version: str
    scratch_path: Path


class ReleaseOperations(Protocol):
    def doctor_package(self, request: ReleaseRequest, plan: ReleasePlan) -> None:
        ...

    def verify_dependency_receipt(self, request: ReleaseRequest) -> None:
        ...

    def run_focused_release_tests(
        self, request: ReleaseRequest, plan: ReleasePlan
    ) -> None:
        ...

    def run_source_gate(self, request: ReleaseRequest, gate: SourceGate) -> None:
        ...

    def package_only(self, request: ReleaseRequest) -> Path:
        ...

    def verify_candidate_receipt(self, request: ReleaseRequest) -> CandidateIdentity:
        ...

    def ensure_annotated_tag(
        self, request: ReleaseRequest, identity: CandidateIdentity
    ) -> None:
        ...

    def wait_exact_sha_ci(
        self, request: ReleaseRequest, identity: CandidateIdentity
    ) -> None:
        ...

    def resume_publish(
        self, request: ReleaseRequest, identity: CandidateIdentity
    ) -> None:
        ...

    def independent_verify(
        self, request: ReleaseRequest, identity: CandidateIdentity
    ) -> None:
        ...


def release_plan(root: Path, channel: str) -> ReleasePlan:
    contract = load_contract(root / "config" / "release-contract.json")
    contract.channel(channel)
    return ReleasePlan(
        focused_release_tests=contract.gates.focusedReleaseTests,
        source_gates=tuple(
            SourceGate(tier=step.tier, require_tools=step.requireTools)
            for step in contract.gates.for_channel(channel)
        ),
    )


class ReleaseCoordinator:
    def __init__(self, operations: ReleaseOperations):
        self.operations = operations

    def execute(self, request: ReleaseRequest) -> CandidateIdentity:
        plan = release_plan(request.root, request.channel)
        active = request
        if request.mode == "prepare":
            self.operations.doctor_package(active, plan)
            self.operations.verify_dependency_receipt(active)
            self.operations.run_focused_release_tests(active, plan)
            for gate in plan.source_gates:
                self.operations.run_source_gate(active, gate)
            receipt = self.operations.package_only(active)
            active = replace(active, receipt=receipt)
        elif request.mode != "resume":
            raise ReleaseError(f"unknown release mode: {request.mode}")

        identity = self.operations.verify_candidate_receipt(active)
        self.operations.ensure_annotated_tag(active, identity)
        self.operations.wait_exact_sha_ci(active, identity)
        self.operations.resume_publish(active, identity)
        self.operations.independent_verify(active, identity)
        return identity


def _read_bounded_json(path: Path, label: str) -> dict[str, Any]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ReleaseError(f"{label} is unavailable: {path}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ReleaseError(f"{label} must be a regular non-symlink file")
    if metadata.st_size <= 0 or metadata.st_size > MAX_JSON_BYTES:
        raise ReleaseError(f"{label} has an invalid size")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReleaseError(f"{label} is not valid JSON") from error
    if not isinstance(value, dict):
        raise ReleaseError(f"{label} must contain a JSON object")
    return value


def _swift_manifest_hash(manifest: dict[str, Any]) -> str:
    encoded = json.dumps(
        manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).replace("/", "\\/")
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_dependency_receipt_file(root: Path, receipt_path: Path) -> None:
    manifest_path = (
        root
        / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"
    )
    manifest = _read_bounded_json(manifest_path, "managed dependency manifest")
    receipt = _read_bounded_json(receipt_path, "dependency receipt")
    expected_set = manifest.get("dependencySet")
    expected_hash = _swift_manifest_hash(manifest)
    if receipt.get("schemaVersion") != 1:
        raise ReleaseError("dependency receipt schema is unsupported")
    if not isinstance(expected_set, str) or not expected_set:
        raise ReleaseError("managed dependency manifest has no dependency set")
    if receipt.get("dependencySet") != expected_set:
        raise ReleaseError("dependency receipt set does not match the manifest")
    if receipt.get("manifestHash") != expected_hash:
        raise ReleaseError(
            "dependency receipt hash does not match the canonical manifest"
        )
    if receipt.get("synthesized") is not False:
        raise ReleaseError("dependency receipt must be reconciled, not synthesized")

    required_environments = {
        entry.get("environment")
        for entry in manifest.get("tools", [])
        if isinstance(entry, dict) and isinstance(entry.get("environment"), str)
    }
    environments = receipt.get("environments")
    if not isinstance(environments, dict):
        raise ReleaseError("dependency receipt environments are malformed")
    incomplete = sorted(
        name
        for name in required_environments
        if not isinstance(environments.get(name), dict)
        or environments[name].get("state") != "installed"
    )
    if incomplete:
        raise ReleaseError(
            f"dependency receipt has {len(incomplete)} incomplete environments"
        )


def required_ci_jobs(channel: str) -> tuple[str, ...]:
    common = (
        "Release context",
        "Fast gate",
        "Focused release tests",
        "Dependency receipt",
    )
    if channel == "preview":
        return (*common, "Preview source gates")
    if channel == "stable":
        return (*common, "Stable full gate", "Stable conformance gate")
    raise ReleaseError(f"unknown release channel: {channel}")


def evaluate_actions_runs(
    runs: list[dict[str, Any]],
    jobs: list[dict[str, Any]],
    *,
    channel: str,
    tag: str,
    expected_sha: str,
) -> int:
    exact = [
        run
        for run in runs
        if run.get("headSha") == expected_sha and run.get("headBranch") == tag
    ]
    if not exact:
        raise ReleaseError("GitHub Actions returned no run for the exact tagged SHA")
    if len(exact) != 1:
        raise ReleaseError(
            "GitHub Actions returned ambiguous runs for the exact tagged SHA"
        )
    run = exact[0]
    status = run.get("status")
    conclusion = run.get("conclusion")
    if status != "completed":
        raise ReleaseError(f"exact-SHA GitHub Actions run is not complete: {status}")
    if conclusion != "success":
        raise ReleaseError(f"exact-SHA GitHub Actions run concluded {conclusion}")
    run_id = run.get("databaseId")
    if type(run_id) is not int or run_id <= 0:
        raise ReleaseError("exact-SHA GitHub Actions run has no valid database id")

    for name in required_ci_jobs(channel):
        matches = [job for job in jobs if job.get("name") == name]
        if not matches:
            raise ReleaseError(f"required GitHub Actions job is missing: {name}")
        if len(matches) != 1:
            raise ReleaseError(f"required GitHub Actions job is ambiguous: {name}")
        job = matches[0]
        job_status = job.get("status")
        job_conclusion = job.get("conclusion")
        if job_status != "completed":
            raise ReleaseError(f"required GitHub Actions job is incomplete: {name}")
        if job_conclusion != "success":
            raise ReleaseError(
                f"required GitHub Actions job {name} concluded {job_conclusion}"
            )
    return run_id


class SubprocessRunner:
    def __init__(self, root: Path, environment: dict[str, str] | None = None):
        self.root = root
        self.environment = os.environ.copy()
        self.github_repository = ""
        if environment:
            self.environment.update(environment)
            configured_repository = environment.get("GH_REPO", "")
            if configured_repository:
                self.github_repository = (
                    configured_repository
                    if configured_repository.startswith("github.com/")
                    else f"github.com/{configured_repository}"
                )
                self.environment["GH_REPO"] = self.github_repository
                self.environment.pop("GH_HOST", None)

    def run(
        self,
        command: list[str],
        *,
        capture: bool = False,
        env: dict[str, str] | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        effective_command = command
        if command and command[0] == "gh" and self.github_repository:
            effective_command = [
                "gh",
                "--repo",
                self.github_repository,
                *command[1:],
            ]
        command_environment = self.environment.copy()
        if env:
            command_environment.update(env)
        result = subprocess.run(
            effective_command,
            cwd=self.root,
            env=command_environment,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            check=False,
        )
        if capture and len((result.stdout or "").encode()) > MAX_JSON_BYTES:
            raise ReleaseError(f"command output exceeded bound: {command[0]}")
        if check and result.returncode != 0:
            raise ReleaseError(
                f"command failed with exit {result.returncode}: {command[0]}"
            )
        return result

    def text(self, command: list[str]) -> str:
        return self.run(command, capture=True).stdout or ""

    def json(self, command: list[str]) -> Any:
        raw = self.text(command)
        try:
            return json.loads(raw)
        except json.JSONDecodeError as error:
            raise ReleaseError(
                f"command returned invalid JSON: {command[0]}"
            ) from error


def _repository_identity(
    runner: SubprocessRunner,
    remote: str,
    expected_repository: str | None = None,
) -> RepositoryIdentity:
    fetch = runner.run(
        ["git", "remote", "get-url", "--all", remote],
        capture=True,
        check=False,
    )
    push = runner.run(
        ["git", "remote", "get-url", "--all", "--push", remote],
        capture=True,
        check=False,
    )
    if fetch.returncode != 0 or push.returncode != 0:
        raise ReleaseError("selected Git remote is unavailable")
    try:
        return repository_identity_from_endpoints(
            remote,
            [line for line in (fetch.stdout or "").splitlines() if line.strip()],
            [line for line in (push.stdout or "").splitlines() if line.strip()],
            expected_repository,
        )
    except RepositoryIdentityError as error:
        raise ReleaseError(str(error)) from error


def _candidate_receipt_identity(
    root: Path, receipt_path: Path, channel: str
) -> CandidateIdentity:
    receipt = _read_bounded_json(receipt_path, "unsigned candidate receipt")
    try:
        commit = receipt["source"]["commit"]
        release = receipt["release"]
        receipt_channel = release["channel"]
        version = release["version"]
        scratch = receipt["build"]["scratchPath"]
    except (KeyError, TypeError) as error:
        raise ReleaseError(
            "unsigned candidate receipt identity is incomplete"
        ) from error
    if not isinstance(commit, str) or HEX_COMMIT.fullmatch(commit) is None:
        raise ReleaseError("unsigned candidate receipt commit is invalid")
    if receipt_channel != channel:
        raise ReleaseError("unsigned candidate receipt channel does not match")
    if not isinstance(version, str) or CALVER.fullmatch(version) is None:
        raise ReleaseError("unsigned candidate receipt version is not canonical CalVer")
    if not isinstance(scratch, str) or not scratch.startswith("/"):
        raise ReleaseError("unsigned candidate receipt scratch path is invalid")
    return CandidateIdentity(
        receipt=receipt_path,
        tag=f"v{version}",
        commit=commit,
        version=version,
        scratch_path=Path(scratch),
    )


def verify_candidate_receipt_exact(
    root: Path,
    receipt_path: Path,
    channel_name: str,
    runner: SubprocessRunner,
) -> CandidateIdentity:
    """Run the canonical receipt verifier and return its trusted identity."""
    identity = _candidate_receipt_identity(root, receipt_path, channel_name)
    current = runner.text(["git", "rev-parse", "HEAD"]).strip()
    if current != identity.commit:
        raise ReleaseError("candidate receipt commit does not match HEAD")
    channel = load_contract(root / "config/release-contract.json").channel(channel_name)
    app = identity.receipt.parent / channel.appBundleFilename
    runner.run(
        [
            str(root / "scripts/release/release-candidate-receipt.py"),
            "verify",
            "--app",
            str(app),
            "--receipt",
            str(identity.receipt),
            "--channel",
            channel_name,
            "--scratch-path",
            str(identity.scratch_path),
        ],
        capture=True,
        env={"PYTHONDONTWRITEBYTECODE": "1"},
    )
    return identity


def _remote_tag_commit(raw: str, tag: str) -> tuple[str, str]:
    direct = ""
    peeled = ""
    for line in raw.splitlines():
        fields = line.split()
        if len(fields) != 2:
            raise ReleaseError("remote tag response is malformed")
        commit, ref = fields
        if HEX_COMMIT.fullmatch(commit) is None:
            raise ReleaseError("remote tag response commit is malformed")
        if ref == f"refs/tags/{tag}":
            if direct:
                raise ReleaseError("remote tag response is ambiguous")
            direct = fields[0]
        elif ref == f"refs/tags/{tag}^{{}}":
            if peeled:
                raise ReleaseError("remote tag response is ambiguous")
            peeled = fields[0]
        else:
            raise ReleaseError("remote tag response is out of scope")
    return direct, peeled


def _remote_release_payload(
    runner: SubprocessRunner, tag: str, label: str
) -> dict[str, Any] | None:
    result = runner.run(
        [
            "gh",
            "release",
            "view",
            tag,
            "--json",
            "targetCommitish,isPrerelease,isDraft,assets,url",
        ],
        capture=True,
        check=False,
    )
    if result.returncode == 1:
        return None
    if result.returncode != 0:
        raise ReleaseError(f"could not inspect {label}")
    try:
        payload = json.loads(result.stdout or "")
    except json.JSONDecodeError as error:
        raise ReleaseError(f"{label} response is malformed") from error
    if not isinstance(payload, dict):
        raise ReleaseError(f"{label} response is malformed")
    return payload


def _publication_asset_state(
    payload: dict[str, Any],
    expected_name: str,
    label: str,
    local_identity: tuple[str, int] | None = None,
    *,
    require_local_identity: bool = False,
) -> str:
    assets = payload.get("assets")
    if not isinstance(assets, list):
        raise ReleaseError(f"{label} assets are malformed")
    matches = [
        asset
        for asset in assets
        if isinstance(asset, dict) and asset.get("name") == expected_name
    ]
    if not matches:
        return "incomplete"
    if len(matches) != 1:
        raise ReleaseError(f"{label} asset is ambiguous")
    asset = matches[0]
    digest = asset.get("digest")
    size = asset.get("size")
    if (
        not isinstance(digest, str)
        or not digest.startswith("sha256:")
        or HEX_SHA256.fullmatch(digest.removeprefix("sha256:")) is None
        or type(size) is not int
        or size <= 0
    ):
        raise ReleaseError(f"{label} asset digest or size is malformed")
    if require_local_identity:
        if local_identity is None:
            return "incomplete"
        local_digest, local_size = local_identity
        if digest != f"sha256:{local_digest}" or size != local_size:
            return "incomplete"
    return "complete"


def _publication_release_state(
    payload: dict[str, Any] | None,
    *,
    identity: CandidateIdentity,
    prerelease: bool,
    asset_name: str,
    label: str,
    local_identity: tuple[str, int] | None = None,
    require_local_identity: bool = False,
) -> str:
    if payload is None:
        return "incomplete"
    if payload.get("targetCommitish") != identity.commit:
        raise ReleaseError(f"{label} target is not the candidate commit")
    if payload.get("isDraft") is not False:
        raise ReleaseError(f"{label} is a draft")
    if payload.get("isPrerelease") is not prerelease:
        raise ReleaseError(f"{label} channel state is wrong")
    return _publication_asset_state(
        payload,
        asset_name,
        label,
        local_identity,
        require_local_identity=require_local_identity,
    )


def _optional_local_mutable_identities(
    root: Path,
    channel_name: str,
    identity: CandidateIdentity,
    *,
    primary_filename: str,
    bridge_filename: str | None,
) -> tuple[tuple[str, int] | None, tuple[str, int] | None]:
    receipt_path = identity.receipt
    metadata_path = receipt_path.parent / "release-metadata.txt"
    if not metadata_path.exists() and not metadata_path.is_symlink():
        return None, None
    metadata = _metadata(metadata_path)
    if metadata.get("version") != identity.version:
        raise ReleaseError("local completion metadata version conflicts with candidate")
    if metadata.get("channel") != channel_name:
        raise ReleaseError("local completion metadata channel conflicts with candidate")
    if metadata.get("git_commit") != identity.commit:
        raise ReleaseError("local completion metadata commit conflicts with candidate")

    release_dir = receipt_path.parent.resolve(strict=True)

    def local_identity_for(
        path_key: str,
        digest_key: str,
        size_key: str,
        expected_filename: str,
        label: str,
    ) -> tuple[str, int] | None:
        value = metadata.get(path_key, "")
        digest = metadata.get(digest_key, "")
        size_value = metadata.get(size_key, "")
        if not value and not digest and not size_value:
            return None
        if not value or not digest or not size_value:
            raise ReleaseError(f"{label} local completion identity is incomplete")
        if HEX_SHA256.fullmatch(digest) is None or not size_value.isdigit():
            raise ReleaseError(f"{label} local completion identity is malformed")
        size = int(size_value)
        if size <= 0:
            raise ReleaseError(f"{label} local completion size is malformed")
        raw_path = Path(value)
        path = raw_path if raw_path.is_absolute() else root / raw_path
        expected_path = release_dir / "sparkle-appcast" / expected_filename
        if path != expected_path:
            raise ReleaseError(
                f"{label} local completion path is not the contract artifact"
            )
        current = release_dir
        for part in ("sparkle-appcast", expected_filename):
            current /= part
            try:
                component = current.lstat()
            except FileNotFoundError:
                return None
            except OSError as error:
                raise ReleaseError(
                    f"{label} local completion path is unavailable"
                ) from error
            if stat.S_ISLNK(component.st_mode):
                raise ReleaseError(f"{label} local completion path contains a symlink")
        if path.resolve(strict=True) != expected_path:
            raise ReleaseError(f"{label} local completion path is not canonical")
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise ReleaseError(f"{label} local completion artifact is unsafe")
        if info.st_size != size or _sha256_file(path) != digest:
            raise ReleaseError(
                f"{label} local completion identity conflicts with bytes"
            )
        return digest, size

    primary = local_identity_for(
        "sparkle_appcast_path",
        "sparkle_appcast_sha256",
        "sparkle_appcast_size",
        primary_filename,
        "primary appcast",
    )
    bridge = None
    if bridge_filename:
        bridge = local_identity_for(
            "sparkle_bridge_appcast_path",
            "sparkle_bridge_appcast_sha256",
            "sparkle_bridge_appcast_size",
            bridge_filename,
            "legacy bridge appcast",
        )
    return primary, bridge


def tagged_publication_state(
    root: Path,
    remote: str,
    channel_name: str,
    identity: CandidateIdentity,
    expected_repository: str | None = None,
) -> str:
    """Classify an exact tagged transaction as incomplete or complete.

    Existing conflicting release state fails closed. The selected Git remote is
    the sole source of repository identity for both Git and GitHub inspection.
    """

    try:
        repository = resolve_repository_identity(root, remote, expected_repository)
    except RepositoryIdentityError as error:
        raise ReleaseError(str(error)) from error
    runner = SubprocessRunner(root, {"GH_REPO": repository.github_repository})
    raw = runner.text(
        [
            "git",
            "ls-remote",
            "--tags",
            remote,
            f"refs/tags/{identity.tag}",
            f"refs/tags/{identity.tag}^{{}}",
        ]
    )
    direct, peeled = _remote_tag_commit(raw, identity.tag)
    if not direct and not peeled:
        return "untagged"
    if not direct or not peeled or peeled != identity.commit:
        raise ReleaseError("current release tag is not exact for the candidate commit")

    verified_identity = verify_candidate_receipt_exact(
        root, identity.receipt, channel_name, runner
    )
    if (
        verified_identity.commit != identity.commit
        or verified_identity.version != identity.version
        or verified_identity.tag != identity.tag
    ):
        raise ReleaseError("verified candidate receipt conflicts with tagged identity")
    identity = verified_identity

    contract = load_contract(root / "config/release-contract.json")
    channel = contract.channel(channel_name)
    local_primary, local_bridge = _optional_local_mutable_identities(
        root,
        channel_name,
        identity,
        primary_filename=channel.appcastFilename,
        bridge_filename=(
            channel.legacyBridgeAppcastFilename if channel.legacyBridgeRelease else None
        ),
    )
    checks = [
        _publication_release_state(
            _remote_release_payload(runner, identity.tag, "immutable release"),
            identity=identity,
            prerelease=channel.githubPrerelease,
            asset_name=f"Lungfish-{identity.version}-arm64.dmg",
            label="immutable release",
        ),
        _publication_release_state(
            _remote_release_payload(
                runner, channel.sparkleRelease, "mutable Sparkle feed"
            ),
            identity=identity,
            prerelease=True,
            asset_name=channel.appcastFilename,
            label="mutable Sparkle feed",
            local_identity=local_primary,
            require_local_identity=True,
        ),
    ]
    if channel.legacyBridgeRelease:
        if not channel.legacyBridgeAppcastFilename:
            raise ReleaseError("legacy Sparkle bridge filename is unavailable")
        checks.append(
            _publication_release_state(
                _remote_release_payload(
                    runner, channel.legacyBridgeRelease, "legacy Sparkle bridge"
                ),
                identity=identity,
                prerelease=True,
                asset_name=channel.legacyBridgeAppcastFilename,
                label="legacy Sparkle bridge",
                local_identity=local_bridge,
                require_local_identity=True,
            )
        )
    return "complete" if all(state == "complete" for state in checks) else "incomplete"


def _metadata(path: Path) -> dict[str, str]:
    try:
        info = path.lstat()
    except OSError as error:
        raise ReleaseError("release metadata is unavailable") from error
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise ReleaseError("release metadata must be a regular file")
    if info.st_size <= 0 or info.st_size > MAX_METADATA_BYTES:
        raise ReleaseError("release metadata size is invalid")
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.partition("=")
        if not separator or not re.fullmatch(r"[A-Za-z0-9_]+", key):
            raise ReleaseError("release metadata has a malformed record")
        if key in values:
            raise ReleaseError("release metadata contains a duplicate key")
        values[key] = value
    return values


def _contained_artifact(release_dir: Path, value: str, label: str) -> Path:
    if not value:
        raise ReleaseError(f"release metadata is missing {label}")
    path = Path(value)
    if not path.is_absolute():
        path = release_dir.parents[1] / path
    resolved = path.resolve(strict=True)
    try:
        resolved.relative_to(release_dir.resolve(strict=True))
    except ValueError as error:
        raise ReleaseError(
            f"{label} is outside the verified release directory"
        ) from error
    return resolved


def _verify_exact_remote_asset(
    payload: dict[str, Any], local_path: Path, expected_name: str, label: str
) -> None:
    try:
        info = local_path.lstat()
    except OSError as error:
        raise ReleaseError(f"{label} local artifact is unavailable") from error
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise ReleaseError(f"{label} local artifact must be a regular file")
    assets = payload.get("assets")
    if not isinstance(assets, list):
        raise ReleaseError(f"{label} assets are malformed")
    matches = [
        asset
        for asset in assets
        if isinstance(asset, dict) and asset.get("name") == expected_name
    ]
    if len(matches) != 1:
        qualifier = "missing" if not matches else "ambiguous"
        raise ReleaseError(f"{label} asset is {qualifier}: {expected_name}")
    asset = matches[0]
    digest = _sha256_file(local_path)
    if asset.get("digest") != f"sha256:{digest}":
        raise ReleaseError(f"{label} digest is wrong or unavailable")
    remote_size = asset.get("size")
    if type(remote_size) is not int or remote_size != info.st_size:
        raise ReleaseError(f"{label} size is wrong or unavailable")


def _verify_mutable_release_identity(
    payload: Any, identity: CandidateIdentity, label: str
) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ReleaseError(f"{label} response is malformed")
    if payload.get("targetCommitish") != identity.commit:
        raise ReleaseError(f"{label} target is not the candidate commit")
    if payload.get("isDraft") is not False:
        raise ReleaseError(f"{label} is a draft")
    if payload.get("isPrerelease") is not True:
        raise ReleaseError(f"{label} channel state is wrong")
    return payload


class LocalReleaseOperations:
    def __init__(self, root: Path, github_repository: str = ""):
        self.root = root.resolve(strict=True)
        environment = {"GH_REPO": github_repository} if github_repository else None
        self.runner = SubprocessRunner(self.root, environment)
        self.contract = load_contract(self.root / "config/release-contract.json")

    def _paths(self, request: ReleaseRequest) -> tuple[Path, Path, Path]:
        release_dir = request.release_dir.resolve()
        return (
            release_dir.parent / "Lungfish.xcarchive",
            self.root / ".build/release-derived-data",
            release_dir,
        )

    def doctor_package(self, request: ReleaseRequest, _plan: ReleasePlan) -> None:
        # This is the coordinator's request-level gate. The builder repeats the
        # Doctor at its destructive mutation boundary as defense for direct use.
        archive, derived, release_dir = self._paths(request)
        commit = self.runner.text(["git", "rev-parse", "HEAD"]).strip()
        scratch = (
            Path(
                os.environ.get(
                    "LUNGFISH_RELEASE_SCRATCH_ROOT",
                    "/private/var/tmp/lungfish-release-swiftpm",
                )
            )
            / _repository_identity(
                self.runner, request.remote, request.github_repository
            ).repository_key
            / commit
        )
        self.runner.run(
            [
                sys.executable,
                str(SCRIPT_DIR / "release-doctor.py"),
                "--mode",
                "package",
                "--channel",
                request.channel,
                "--scratch-path",
                str(scratch),
                "--release-dir",
                str(release_dir),
                "--archive-path",
                str(archive),
                "--derived-data-path",
                str(derived),
                "--remote",
                request.remote,
                "--github-repository",
                request.github_repository,
            ]
        )

    def verify_dependency_receipt(self, request: ReleaseRequest) -> None:
        verify_dependency_receipt_file(self.root, request.dependency_receipt)

    def run_focused_release_tests(
        self, _request: ReleaseRequest, plan: ReleasePlan
    ) -> None:
        python = self.root / ".ci-python/bin/python"
        executable = str(python if python.is_file() else Path(sys.executable))
        self.runner.run(
            [executable, "-B", "-m", "unittest", *plan.focused_release_tests]
        )

    def run_source_gate(self, _request: ReleaseRequest, gate: SourceGate) -> None:
        command = [
            "/bin/bash",
            str(self.root / "scripts/full-suite-gate.sh"),
            "--tier",
            gate.tier,
        ]
        if gate.require_tools:
            command.append("--require-tools")
        self.runner.run(command)

    def package_only(self, request: ReleaseRequest) -> Path:
        archive, derived, release_dir = self._paths(request)
        command = [
            "/bin/bash",
            str(SCRIPT_DIR / "build-notarized-dmg.sh"),
            "--package-only",
            "--channel",
            request.channel,
            "--release-dir",
            str(release_dir),
            "--archive-path",
            str(archive),
            "--derived-data-path",
            str(derived),
            "--sparkle-public-ed-key",
            request.sparkle_public_ed_key,
            "--remote",
            request.remote,
            "--github-repository",
            request.github_repository,
        ]
        self.runner.run(command)
        receipt = release_dir / "unsigned-candidate-receipt.json"
        if not receipt.is_file():
            raise ReleaseError("package phase did not produce a candidate receipt")
        return receipt

    def verify_candidate_receipt(self, request: ReleaseRequest) -> CandidateIdentity:
        return verify_candidate_receipt_exact(
            self.root,
            request.receipt,
            request.channel,
            self.runner,
        )

    def _remote_tag(
        self, request: ReleaseRequest, identity: CandidateIdentity
    ) -> tuple[str, str]:
        raw = self.runner.text(
            [
                "git",
                "ls-remote",
                "--tags",
                request.remote,
                f"refs/tags/{identity.tag}",
                f"refs/tags/{identity.tag}^{{}}",
            ]
        )
        return _remote_tag_commit(raw, identity.tag)

    def ensure_annotated_tag(
        self, request: ReleaseRequest, identity: CandidateIdentity
    ) -> None:
        branch = self.runner.text(["git", "branch", "--show-current"]).strip()
        if branch != request.main_branch:
            raise ReleaseError(
                f"release source must be on {request.main_branch}, not {branch or 'detached HEAD'}"
            )
        direct, peeled = self._remote_tag(request, identity)
        if direct or peeled:
            if not direct or peeled != identity.commit:
                raise ReleaseError(
                    "remote release tag does not peel to the candidate commit"
                )
            return

        release_view = self.runner.run(
            ["gh", "release", "view", identity.tag], capture=True, check=False
        )
        if release_view.returncode == 0:
            raise ReleaseError("GitHub release exists before its version tag")
        local_type = self.runner.run(
            ["git", "cat-file", "-t", identity.tag], capture=True, check=False
        )
        if local_type.returncode == 0:
            if (local_type.stdout or "").strip() != "tag":
                raise ReleaseError("local release tag is not annotated")
            local_commit = self.runner.text(
                ["git", "rev-parse", f"{identity.tag}^{{commit}}"]
            ).strip()
            if local_commit != identity.commit:
                raise ReleaseError("local release tag points to another commit")
        else:
            self.runner.run(
                [
                    "git",
                    "tag",
                    "-a",
                    identity.tag,
                    identity.commit,
                    "-m",
                    f"Lungfish {identity.tag}",
                ]
            )
        self.runner.run(
            [
                "git",
                "push",
                "--atomic",
                request.remote,
                request.main_branch,
                identity.tag,
            ]
        )
        direct, peeled = self._remote_tag(request, identity)
        if not direct or peeled != identity.commit:
            raise ReleaseError("pushed annotated tag failed exact commit verification")

    def _gh_runs(self, identity: CandidateIdentity) -> list[dict[str, Any]]:
        value = self.runner.json(
            [
                "gh",
                "run",
                "list",
                "--workflow",
                "ci.yml",
                "--event",
                "push",
                "--commit",
                identity.commit,
                "--limit",
                "20",
                "--json",
                "databaseId,headSha,headBranch,status,conclusion",
            ]
        )
        if not isinstance(value, list) or not all(
            isinstance(item, dict) for item in value
        ):
            raise ReleaseError("GitHub Actions run response is malformed")
        return value

    def wait_exact_sha_ci(
        self, request: ReleaseRequest, identity: CandidateIdentity
    ) -> None:
        deadline = time.monotonic() + request.ci_timeout_seconds
        while True:
            runs = self._gh_runs(identity)
            exact = [
                run
                for run in runs
                if run.get("headSha") == identity.commit
                and run.get("headBranch") == identity.tag
            ]
            wrong = [run for run in runs if run.get("headSha") != identity.commit]
            if wrong:
                raise ReleaseError("GitHub Actions returned a run for the wrong SHA")
            if exact and exact[0].get("status") == "completed":
                run_id = exact[0].get("databaseId")
                jobs_value = self.runner.json(
                    ["gh", "run", "view", str(run_id), "--json", "jobs"]
                )
                jobs = jobs_value.get("jobs") if isinstance(jobs_value, dict) else None
                if not isinstance(jobs, list) or not all(
                    isinstance(item, dict) for item in jobs
                ):
                    raise ReleaseError("GitHub Actions jobs response is malformed")
                evaluate_actions_runs(
                    runs,
                    jobs,
                    channel=request.channel,
                    tag=identity.tag,
                    expected_sha=identity.commit,
                )
                return
            if time.monotonic() >= deadline:
                raise ReleaseError(
                    "timed out waiting for exact tagged SHA GitHub Actions gates"
                )
            time.sleep(request.ci_poll_seconds)

    def _versioned_release_exists(self, tag: str) -> bool:
        return (
            self.runner.run(
                ["gh", "release", "view", tag], capture=True, check=False
            ).returncode
            == 0
        )

    def resume_publish(
        self, request: ReleaseRequest, identity: CandidateIdentity
    ) -> None:
        if not all((request.signing_identity, request.team_id, request.notary_profile)):
            raise ReleaseError(
                "credentialed release requires identity, team, and notary profile"
            )
        if not request.sparkle_generate_appcast.is_file():
            raise ReleaseError("Sparkle generate_appcast is unavailable")
        command = [
            "/bin/bash",
            str(SCRIPT_DIR / "build-notarized-dmg.sh"),
            "--resume-candidate",
            str(identity.receipt),
            "--channel",
            request.channel,
            "--signing-identity",
            request.signing_identity,
            "--team-id",
            request.team_id,
            "--notary-profile",
            request.notary_profile,
            "--github-release-tag",
            identity.tag,
            "--sparkle-public-ed-key",
            request.sparkle_public_ed_key,
            "--sparkle-generate-appcast",
            str(request.sparkle_generate_appcast),
            "--remote",
            request.remote,
            "--github-repository",
            request.github_repository,
        ]
        if request.sparkle_ed_key_file is not None:
            command.extend(["--sparkle-ed-key-file", str(request.sparkle_ed_key_file)])
        if self._versioned_release_exists(identity.tag):
            command.append("--recover-existing-release")
        if request.channel == "preview" and request.prune_prereleases:
            command.extend(
                [
                    "--prune-prereleases",
                    "--prune-prereleases-keep",
                    str(request.prune_prereleases_keep),
                ]
            )
        self.runner.run(command)

    def independent_verify(
        self, request: ReleaseRequest, identity: CandidateIdentity
    ) -> None:
        metadata = _metadata(identity.receipt.parent / "release-metadata.txt")
        if metadata.get("version") != identity.version:
            raise ReleaseError("release metadata version does not match the candidate")
        if metadata.get("channel") != request.channel:
            raise ReleaseError("release metadata channel does not match the candidate")
        if metadata.get("git_commit") != identity.commit:
            raise ReleaseError("release metadata commit does not match the candidate")
        release_dir = identity.receipt.parent
        dmg = _contained_artifact(release_dir, metadata.get("DMG_PATH", ""), "DMG_PATH")
        signed_app = _contained_artifact(
            release_dir,
            metadata.get("app_path", ""),
            "app_path",
        )
        digest = _sha256_file(dmg)
        if HEX_SHA256.fullmatch(digest) is None or metadata.get("dmg_sha256") != digest:
            raise ReleaseError("independent DMG checksum verification failed")
        self.runner.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(signed_app)]
        )
        self.runner.run(["/usr/bin/xcrun", "stapler", "validate", str(signed_app)])
        self.runner.run(["/usr/bin/xcrun", "stapler", "validate", str(dmg)])
        self.runner.run(
            [
                "/usr/sbin/spctl",
                "-a",
                "-vv",
                "-t",
                "open",
                "--context",
                "context:primary-signature",
                str(dmg),
            ]
        )
        self.runner.run(
            [str(self.root / "scripts/smoke-test-release-tools.sh"), str(signed_app)]
        )

        release = self.runner.json(
            [
                "gh",
                "release",
                "view",
                identity.tag,
                "--json",
                "targetCommitish,isPrerelease,isDraft,assets,url",
            ]
        )
        channel = self.contract.channel(request.channel)
        if not isinstance(release, dict):
            raise ReleaseError("published GitHub release response is malformed")
        if release.get("targetCommitish") != identity.commit:
            raise ReleaseError(
                "published GitHub release target is not the candidate commit"
            )
        if release.get("isDraft") is not False:
            raise ReleaseError("published GitHub release is a draft")
        if release.get("isPrerelease") is not channel.githubPrerelease:
            raise ReleaseError("published GitHub release channel state is wrong")
        _verify_exact_remote_asset(
            release, dmg, dmg.name, "published GitHub release DMG"
        )

        appcast = _contained_artifact(
            release_dir,
            metadata.get("sparkle_appcast_path", ""),
            "sparkle_appcast_path",
        )

        feed = self.runner.json(
            [
                "gh",
                "release",
                "view",
                channel.sparkleRelease,
                "--json",
                "targetCommitish,isPrerelease,isDraft,assets,url",
            ]
        )
        feed = _verify_mutable_release_identity(feed, identity, "mutable Sparkle feed")
        _verify_exact_remote_asset(
            feed, appcast, channel.appcastFilename, "mutable Sparkle feed appcast"
        )
        if channel.legacyBridgeRelease:
            if not channel.legacyBridgeAppcastFilename:
                raise ReleaseError("legacy Sparkle bridge filename is unavailable")
            bridge_appcast = _contained_artifact(
                release_dir,
                str(appcast.parent / channel.legacyBridgeAppcastFilename),
                "legacy Sparkle bridge appcast",
            )
            bridge = self.runner.json(
                [
                    "gh",
                    "release",
                    "view",
                    channel.legacyBridgeRelease,
                    "--json",
                    "targetCommitish,isPrerelease,isDraft,assets,url",
                ]
            )
            bridge = _verify_mutable_release_identity(
                bridge, identity, "legacy Sparkle bridge"
            )
            _verify_exact_remote_asset(
                bridge,
                bridge_appcast,
                channel.legacyBridgeAppcastFilename,
                "legacy Sparkle bridge appcast",
            )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("channel", choices=("preview", "stable"))
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--prepare", action="store_true")
    mode.add_argument("--resume", type=Path, metavar="RECEIPT")
    mode.add_argument("--verify-dependency-receipt", type=Path, metavar="RECEIPT")
    parser.add_argument("--repo", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--release-dir", type=Path)
    parser.add_argument("--dependency-receipt", type=Path)
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--github-repository")
    parser.add_argument("--main-branch", default="main")
    parser.add_argument("--signing-identity", default="")
    parser.add_argument("--team-id", default="")
    parser.add_argument("--notary-profile", default="")
    parser.add_argument("--sparkle-generate-appcast", type=Path)
    parser.add_argument("--sparkle-public-ed-key", default=PUBLIC_SPARKLE_KEY)
    parser.add_argument("--sparkle-ed-key-file", type=Path)
    parser.add_argument("--ci-timeout-seconds", type=int, default=6 * 60 * 60)
    parser.add_argument("--ci-poll-seconds", type=int, default=30)
    prune = parser.add_mutually_exclusive_group()
    prune.add_argument(
        "--prune-prereleases", dest="prune", action="store_true", default=True
    )
    prune.add_argument("--no-prune-prereleases", dest="prune", action="store_false")
    parser.add_argument("--prune-prereleases-keep", type=int, default=10)
    return parser


def _required_path(value: Path | None, label: str) -> Path:
    if value is None:
        raise ReleaseError(f"{label} is required")
    return value.expanduser().absolute()


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        root = args.repo.expanduser().resolve(strict=True)
        if args.verify_dependency_receipt is not None:
            verify_dependency_receipt_file(
                root, args.verify_dependency_receipt.expanduser().absolute()
            )
            print("Dependency receipt: PASS")
            return 0
        if not 1 <= args.ci_poll_seconds <= 300:
            raise ReleaseError("CI poll interval must be between 1 and 300 seconds")
        if not 1 <= args.ci_timeout_seconds <= 12 * 60 * 60:
            raise ReleaseError("CI timeout must be between 1 second and 12 hours")
        if args.prune_prereleases_keep < 1:
            raise ReleaseError("prerelease retention count must be positive")
        try:
            repository = resolve_repository_identity(
                root, args.remote, args.github_repository
            )
        except RepositoryIdentityError as error:
            raise ReleaseError(str(error)) from error
        dependency_receipt = args.dependency_receipt
        if dependency_receipt is None:
            configured = os.environ.get("LUNGFISH_DEPENDENCY_RECEIPT", "")
            dependency_receipt = (
                Path(configured)
                if configured
                else Path.home() / ".lungfish-verify/dependency-receipt.json"
            )
        release_dir = (
            args.release_dir.expanduser().resolve()
            if args.release_dir is not None
            else root / "build/Release"
        )
        receipt = (
            args.resume.expanduser().absolute()
            if args.resume is not None
            else release_dir / "unsigned-candidate-receipt.json"
        )
        request = ReleaseRequest(
            root=root,
            channel=args.channel,
            mode="resume" if args.resume is not None else "prepare",
            receipt=receipt,
            remote=args.remote,
            main_branch=args.main_branch,
            signing_identity=args.signing_identity,
            team_id=args.team_id,
            notary_profile=args.notary_profile,
            sparkle_generate_appcast=_required_path(
                args.sparkle_generate_appcast, "--sparkle-generate-appcast"
            ),
            sparkle_ed_key_file=(
                args.sparkle_ed_key_file.expanduser().absolute()
                if args.sparkle_ed_key_file is not None
                else None
            ),
            dependency_receipt=dependency_receipt.expanduser().absolute(),
            release_dir=release_dir,
            ci_timeout_seconds=args.ci_timeout_seconds,
            ci_poll_seconds=args.ci_poll_seconds,
            prune_prereleases=args.prune,
            prune_prereleases_keep=args.prune_prereleases_keep,
            sparkle_public_ed_key=args.sparkle_public_ed_key,
            github_repository=repository.github_repository,
        )
        identity = ReleaseCoordinator(
            LocalReleaseOperations(root, repository.github_repository)
        ).execute(request)
        print(
            f"Release complete: channel={request.channel} tag={identity.tag} commit={identity.commit}"
        )
        return 0
    except (OSError, ReleaseError, ValueError) as error:
        print(f"release failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
