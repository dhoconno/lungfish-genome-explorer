#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import platform
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


TOOL_VERSION = "0.4.0-alpha.12"
FIXTURES = {
    "Tests/Fixtures/analyses/esviritu-batch-2026-01-15T15-00-00": {
        "fixtureWorkflowName": "esviritu-batch-analysis-output",
        "fixtureToolName": "esviritu-batch",
        "purpose": "Retained GUI sidebar fixture for ESViritu batch analysis output.",
    },
    "Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00": {
        "fixtureWorkflowName": "kraken2-classification-output",
        "fixtureToolName": "kraken2",
        "purpose": "Retained classification fixture for Kraken2 and Bracken analysis output.",
    },
    "Tests/Fixtures/analyses/minimap2-2026-01-15T14-00-00": {
        "fixtureWorkflowName": "minimap2-alignment-output",
        "fixtureToolName": "minimap2",
        "purpose": "Retained alignment fixture for minimap2 BAM output.",
    },
    "Tests/Fixtures/analyses/spades-2026-01-15T13-00-00": {
        "fixtureWorkflowName": "spades-assembly-output",
        "fixtureToolName": "spades",
        "purpose": "Retained assembly fixture for SPAdes contig output.",
    },
    "Tests/Fixtures/analyses/taxtriage-2026-01-15T12-00-00": {
        "fixtureWorkflowName": "taxtriage-analysis-output",
        "fixtureToolName": "taxtriage",
        "purpose": "Retained taxonomy triage fixture for TaxTriage report output.",
    },
}
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


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_entries(fixture_path):
    entries = []
    for path in sorted(fixture_path.rglob("*")):
        if not path.is_file() or path.name == ".lungfish-provenance.json":
            continue
        relative = path.relative_to(fixture_path).as_posix()
        entries.append(
            {
                "path": relative,
                "size": path.stat().st_size,
                "checksumSHA256": sha256_file(path),
            }
        )
    return entries


def directory_checksum(entries):
    digest = hashlib.sha256()
    for entry in entries:
        digest.update(entry["path"].encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(entry["size"]).encode("utf-8"))
        digest.update(b"\0")
        digest.update(entry["checksumSHA256"].encode("utf-8"))
        digest.update(b"\n")
    return digest.hexdigest()


def directory_size(entries):
    return sum(entry["size"] for entry in entries)


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
    command = "git checkout 68ae1af0 -- " + shlex.quote(relative_fixture)

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
        "reproducibleCommand": command,
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
        "reproducibleGitCheckoutCommand": command,
        "reproducibleShellCommand": shell_command(executed_argv),
    }


def main():
    args = parse_args()
    root = args.root.resolve()
    created_at = args.created_at or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    executed_argv = sys.argv[:]
    wrote = []
    skipped = []

    for relative_fixture, metadata in FIXTURES.items():
        fixture_path = root / relative_fixture
        sidecar_path = fixture_path / ".lungfish-provenance.json"
        if not fixture_path.is_dir():
            print(f"missing fixture directory: {fixture_path}", file=sys.stderr)
            return 1
        if sidecar_path.exists() and not args.overwrite:
            skipped.append(relative_fixture)
            continue

        record = build_record(root, relative_fixture, metadata, created_at, executed_argv, args.overwrite)
        sidecar_path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        wrote.append(relative_fixture)

    for relative_fixture in wrote:
        print(f"backfilled {relative_fixture}/.lungfish-provenance.json")
    for relative_fixture in skipped:
        print(f"skipped existing {relative_fixture}/.lungfish-provenance.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
