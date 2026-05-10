#!/usr/bin/env python3
import argparse
import json
import os
import platform
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from fixture_provenance import (
    RETAINED_FIXTURES,
    directory_checksum,
    directory_size,
    file_entries,
    validate_fixture_sidecar,
)

TOOL_VERSION = "0.4.0-alpha.12"
WARNING = (
    "This is a historical fixture backfill for repository provenance hygiene; "
    "it records the retained fixture payload and does not claim the original "
    "biological workflow was rerun."
)


def parse_args():
    parser = argparse.ArgumentParser(description="Write provenance sidecars for retained analysis fixtures.")
    parser.add_argument("--root", default=Path(__file__).resolve().parents[2], type=Path)
    parser.add_argument("--created-at", default=None)
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


def git_revision(root):
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip()


def runtime_identity(root):
    return {
        "condaEnvironment": os.environ.get("CONDA_DEFAULT_ENV"),
        "containerImage": os.environ.get("LUNGFISH_CONTAINER_IMAGE"),
        "executablePath": sys.executable,
        "operatingSystemVersion": platform.platform(),
        "processIdentifier": os.getpid(),
        "pythonVersion": platform.python_version(),
        "gitRevision": git_revision(root),
    }


def shell_command(argv):
    return " ".join(shlex.quote(part) for part in argv)


def build_record(root, relative_fixture, metadata, created_at, executed_argv, overwrite_existing):
    fixture_path = root / relative_fixture
    entries = file_entries(fixture_path)
    shell = shell_command(executed_argv)
    checkout_command = "git checkout 68ae1af0 -- " + shlex.quote(relative_fixture)

    return {
        "schemaVersion": 1,
        "workflowName": "analysis-fixture-provenance-historical-backfill",
        "tool": {
            "name": "write-analysis-fixture-provenance.py",
            "version": TOOL_VERSION,
        },
        "toolName": "write-analysis-fixture-provenance.py",
        "toolVersion": TOOL_VERSION,
        "createdAt": created_at,
        "reproducibleCommand": shell,
        "argv": executed_argv,
        "options": {
            "purpose": metadata["purpose"],
            "fixtureWorkflowName": metadata["fixtureWorkflowName"],
            "fixtureToolName": metadata["fixtureToolName"],
            "inputPaths": [],
            "outputDirectory": relative_fixture,
            "resolvedDefaults": {
                "backfillMode": "historical-fixture-sidecar-only",
                "overwriteExistingSidecar": overwrite_existing,
            },
            "userVisibleOptions": {
                "fixtureDirectory": relative_fixture,
                "tool": metadata["fixtureToolName"],
            },
        },
        "runtimeIdentity": runtime_identity(root),
        "output": {
            "path": relative_fixture,
            "fileSize": directory_size(entries),
            "size": directory_size(entries),
            "checksumSHA256": directory_checksum(entries),
        },
        "files": entries,
        "exitStatus": 0,
        "wallTimeSeconds": 0.0,
        "stderr": None,
        "warning": WARNING,
        "warnings": [WARNING],
        "historicalBackfill": True,
        "historicalPayloadCheckoutCommand": checkout_command,
        "reproducibleGitCheckoutCommand": checkout_command,
        "reproducibleShellCommand": shell,
    }


def main():
    args = parse_args()
    root = args.root.resolve()
    created_at = args.created_at or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    executed_argv = sys.argv[:]
    wrote = []
    repaired = []
    overwritten = []
    skipped = []

    for relative_fixture, metadata in RETAINED_FIXTURES.items():
        fixture_path = root / relative_fixture
        sidecar_path = fixture_path / ".lungfish-provenance.json"
        if not fixture_path.is_dir():
            print(f"missing fixture directory: {fixture_path}", file=sys.stderr)
            return 1

        had_sidecar = sidecar_path.exists()
        validation_errors = validate_fixture_sidecar(root, relative_fixture) if had_sidecar else []
        if had_sidecar and not validation_errors and not args.overwrite:
            skipped.append(relative_fixture)
            continue

        record = build_record(root, relative_fixture, metadata, created_at, executed_argv, args.overwrite)
        sidecar_path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        if args.overwrite and had_sidecar:
            overwritten.append(relative_fixture)
        elif validation_errors:
            repaired.append(relative_fixture)
        else:
            wrote.append(relative_fixture)

    for relative_fixture in wrote:
        print(f"backfilled {relative_fixture}/.lungfish-provenance.json")
    for relative_fixture in repaired:
        print(f"repaired {relative_fixture}/.lungfish-provenance.json")
    for relative_fixture in overwritten:
        print(f"overwrote {relative_fixture}/.lungfish-provenance.json")
    for relative_fixture in skipped:
        print(f"skipped existing {relative_fixture}/.lungfish-provenance.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
