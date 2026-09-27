#!/usr/bin/env python3
"""Exercise micromamba reconciliation through a packaged app's embedded CLI."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from typing import Any


COMMAND_TIMEOUT_SECONDS = 30
WORKFLOW_RESOURCE_RELATIVES = (
    Path(
        "Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/"
        "Contents/Resources"
    ),
    Path("Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle"),
)
PLAN_LIST_FIELDS = (
    "installEnvironments",
    "reinstallEnvironments",
    "removeEnvironments",
    "databaseUpdates",
    "pipelinePrefetch",
    "preservedEnvironments",
)


class SmokeError(ValueError):
    pass


def _regular_file(path: Path, label: str, *, executable: bool = False) -> Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise SmokeError(f"{label} is unavailable") from error
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        raise SmokeError(f"{label} must be a regular non-symlink file")
    if executable and not os.access(path, os.X_OK):
        raise SmokeError(f"{label} must be executable")
    return path


def _workflow_resources(app: Path) -> Path:
    matches = [app / relative for relative in WORKFLOW_RESOURCE_RELATIVES]
    matches = [
        path
        for path in matches
        if path.is_dir()
        and not path.is_symlink()
        and (path / "Tools").is_dir()
        and (path / "ManagedTools").is_dir()
    ]
    if len(matches) != 1:
        raise SmokeError("packaged app must contain exactly one workflow resource directory")
    return matches[0]


def _load_json(path: Path, label: str) -> dict[str, Any]:
    _regular_file(path, label)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SmokeError(f"{label} is not valid JSON") from error
    if not isinstance(value, dict):
        raise SmokeError(f"{label} must contain a JSON object")
    return value


def _parse_package_spec(spec: Any) -> tuple[str, str, str | None]:
    if not isinstance(spec, str):
        raise SmokeError("managed tool packageSpec must be a string")
    rest = spec.split("::", 1)[-1]
    parts = rest.split("=")
    if len(parts) < 2 or not parts[0] or not parts[1]:
        raise SmokeError(f"managed tool packageSpec is invalid: {spec}")
    build = parts[2] if len(parts) >= 3 and parts[2] else None
    return parts[0], parts[1], build


def _seed_required_environments(manifest: dict[str, Any], conda_root: Path) -> None:
    tools = manifest.get("tools")
    if not isinstance(tools, list) or not tools:
        raise SmokeError("managed manifest has no required tools")
    seen: set[str] = set()
    for tool in tools:
        if not isinstance(tool, dict):
            raise SmokeError("managed manifest tool entry must be an object")
        environment = tool.get("environment")
        if not isinstance(environment, str) or not environment or environment in seen:
            raise SmokeError("managed manifest tool environment is invalid or duplicated")
        seen.add(environment)
        name, version, build = _parse_package_spec(tool.get("packageSpec"))
        metadata = {"name": name, "version": version}
        if build is not None:
            metadata["build"] = build
        metadata_dir = conda_root / "envs" / environment / "conda-meta"
        metadata_dir.mkdir(parents=True, exist_ok=False)
        (metadata_dir / f"{name}-{version}.json").write_text(
            json.dumps(metadata, sort_keys=True) + "\n", encoding="utf-8"
        )


def _run_cli(
    cli: Path, storage_root: Path, arguments: list[str]
) -> subprocess.CompletedProcess[str]:
    environment = dict(os.environ)
    environment["LUNGFISH_STORAGE_ROOT"] = str(storage_root)
    environment["LUNGFISH_CONDA_ROOT"] = str(storage_root / "conda")
    try:
        return subprocess.run(
            [str(cli), *arguments, "--storage-root", str(storage_root)],
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SmokeError("embedded CLI bootstrap smoke could not complete") from error


def _json_stdout(result: subprocess.CompletedProcess[str], label: str) -> dict[str, Any]:
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise SmokeError(f"{label} did not produce valid JSON") from error
    if not isinstance(value, dict):
        raise SmokeError(f"{label} did not produce a JSON object")
    return value


def _bounded_apply_failure(result: subprocess.CompletedProcess[str]) -> str:
    try:
        report = json.loads(result.stdout)
        failures = report["result"]["failed"]
    except (json.JSONDecodeError, KeyError, TypeError):
        failures = None
    if isinstance(failures, dict) and failures:
        messages: list[str] = []
        for key in sorted(failures)[:3]:
            value = failures[key]
            if not isinstance(key, str) or not isinstance(value, str):
                continue
            one_line = " ".join(value.split())[:500]
            messages.append(f"{key}: {one_line}")
        if messages:
            return "; ".join(messages)
    stderr = " ".join(result.stderr.split())[:500]
    return stderr or "embedded CLI returned a failure"


def _assert_bootstrap_only_plan(
    plan: dict[str, Any], target_version: str, dependency_set: str
) -> None:
    if plan.get("targetDependencySet") != dependency_set:
        raise SmokeError("bootstrap-only plan selected the wrong dependency set")
    for field in PLAN_LIST_FIELDS:
        if plan.get(field) != []:
            raise SmokeError(f"bootstrap-only plan unexpectedly selected {field}")
    if plan.get("estimatedDownloadBytes") != 0:
        raise SmokeError("bootstrap-only plan unexpectedly estimated a download")
    bootstrap = plan.get("bootstrapUpdate")
    if not isinstance(bootstrap, dict) or bootstrap.get("targetVersion") != target_version:
        raise SmokeError("bootstrap-only plan did not select the pinned micromamba")


def _assert_empty_plan(plan: dict[str, Any], dependency_set: str) -> None:
    if plan.get("targetDependencySet") != dependency_set:
        raise SmokeError("post-apply plan selected the wrong dependency set")
    for field in PLAN_LIST_FIELDS:
        if plan.get(field) != []:
            raise SmokeError(f"post-apply plan retained work in {field}")
    if plan.get("bootstrapUpdate") is not None:
        raise SmokeError("post-apply plan still requests a bootstrap update")
    if plan.get("estimatedDownloadBytes") != 0:
        raise SmokeError("post-apply plan unexpectedly estimated a download")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _assert_apply_evidence(
    storage_root: Path,
    bundled: Path,
    target_version: str,
    dependency_set: str,
    report: dict[str, Any],
) -> None:
    result = report.get("result")
    if not isinstance(result, dict):
        raise SmokeError("bootstrap apply report lacks a result")
    if result.get("succeeded") != ["micromamba"] or result.get("failed") != {}:
        raise SmokeError("bootstrap apply did not succeed exactly once")

    installed = _regular_file(
        storage_root / "conda/bin/micromamba",
        "installed disposable micromamba",
        executable=True,
    )
    if _sha256(installed) != _sha256(bundled):
        raise SmokeError("installed micromamba differs from the packaged executable")
    version = subprocess.run(
        [str(installed), "--version"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=COMMAND_TIMEOUT_SECONDS,
    )
    expected_runtime_version = re.sub(r"-\d+$", "", target_version)
    if version.returncode != 0 or version.stdout.strip() != expected_runtime_version:
        raise SmokeError("installed micromamba does not report the pinned runtime version")

    receipt = _load_json(storage_root / "dependency-receipt.json", "dependency receipt")
    if receipt.get("dependencySet") != dependency_set:
        raise SmokeError("dependency receipt did not stamp the target set")
    bootstrap = receipt.get("bootstrap")
    if not isinstance(bootstrap, dict) or bootstrap.get("micromambaVersion") != target_version:
        raise SmokeError("dependency receipt did not record the bootstrap version")

    provenance_files = sorted(
        (storage_root / "provenance/dependencies").glob("*.lungfish-provenance.json")
    )
    if len(provenance_files) != 1:
        raise SmokeError("bootstrap apply did not write exactly one provenance envelope")
    provenance = _load_json(provenance_files[0], "dependency provenance")
    if provenance.get("workflowName") != "dependency-reconcile" or provenance.get("exitStatus") != 0:
        raise SmokeError("dependency provenance did not record a successful reconciliation")
    steps = provenance.get("steps")
    if not isinstance(steps, list) or len(steps) != 1:
        raise SmokeError("dependency provenance did not record exactly one bootstrap step")
    step = steps[0]
    if not isinstance(step, dict) or any(
        (
            step.get("toolName") != "micromamba",
            step.get("toolVersion") != target_version,
            step.get("exitStatus") != 0,
            step.get("argv") != ["bootstrap", "micromamba"],
        )
    ):
        raise SmokeError("dependency provenance bootstrap step is incomplete")


def verify(app_argument: str) -> None:
    app = Path(app_argument)
    if not app.is_absolute():
        app = (Path.cwd() / app).absolute()
    if not app.is_dir() or app.is_symlink():
        raise SmokeError("app path must be a directory and not a symlink")
    resources = _workflow_resources(app)
    cli = _regular_file(app / "Contents/MacOS/lungfish-cli", "embedded CLI", executable=True)
    bundled = _regular_file(resources / "Tools/micromamba", "bundled micromamba", executable=True)
    manifest = _load_json(
        resources / "ManagedTools/third-party-tools-lock.json", "managed manifest"
    )
    dependency_set = manifest.get("dependencySet")
    bootstrap = manifest.get("bootstrap")
    micromamba = bootstrap.get("micromamba") if isinstance(bootstrap, dict) else None
    target_version = micromamba.get("version") if isinstance(micromamba, dict) else None
    hashes = micromamba.get("sha256") if isinstance(micromamba, dict) else None
    upstream_hash = hashes.get("osx-arm64") if isinstance(hashes, dict) else None
    if not isinstance(dependency_set, str) or not dependency_set:
        raise SmokeError("managed manifest lacks dependencySet")
    if not isinstance(target_version, str) or not target_version:
        raise SmokeError("managed manifest lacks bootstrap.micromamba.version")
    if not isinstance(upstream_hash, str) or re.fullmatch(r"[0-9a-f]{64}", upstream_hash) is None:
        raise SmokeError("managed manifest lacks a valid micromamba osx-arm64 SHA-256")
    if _sha256(bundled) == upstream_hash:
        raise SmokeError("packaged micromamba unexpectedly matches the pre-signing upstream hash")

    with tempfile.TemporaryDirectory(prefix="lungfish-signed-bootstrap-") as directory:
        storage_root = Path(directory)
        _seed_required_environments(manifest, storage_root / "conda")

        plan_result = _run_cli(
            cli, storage_root, ["tools", "update", "--plan", "--json"]
        )
        if plan_result.returncode != 10:
            raise SmokeError("bootstrap-only plan did not exit with updates-pending status")
        plan = _json_stdout(plan_result, "bootstrap-only plan")
        _assert_bootstrap_only_plan(plan, target_version, dependency_set)

        apply_result = _run_cli(
            cli, storage_root, ["tools", "update", "--apply", "--yes", "--json"]
        )
        if apply_result.returncode != 0:
            raise SmokeError(
                f"bootstrap apply failed: {_bounded_apply_failure(apply_result)}"
            )
        apply_report = _json_stdout(apply_result, "bootstrap apply")
        _assert_apply_evidence(
            storage_root, bundled, target_version, dependency_set, apply_report
        )

        second_result = _run_cli(
            cli, storage_root, ["tools", "update", "--plan", "--json"]
        )
        if second_result.returncode != 0:
            raise SmokeError("post-apply plan did not exit successfully")
        _assert_empty_plan(
            _json_stdout(second_result, "post-apply plan"), dependency_set
        )


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"Usage: {Path(argv[0]).name} <Lungfish.app>", file=sys.stderr)
        return 64
    try:
        verify(argv[1])
    except SmokeError as error:
        print(f"FAIL signed-bootstrap-reconciliation: {error}", file=sys.stderr)
        return 1
    print("PASS signed-bootstrap-reconciliation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
