#!/usr/bin/env python3
import argparse
import json
import os
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from fixture_provenance import (
    REQUIRED_MSA_PAYLOAD_FILES,
    RETAINED_FIXTURES,
    directory_checksum,
    directory_size,
    file_entries,
    validate_fixture_sidecar,
)

TOOL_VERSION = "0.4.0-alpha.14"
ALIGNMENT_PROJECT_PATH = "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish"
ALIGNMENT_INPUT_FASTA = f"{ALIGNMENT_PROJECT_PATH}/Inputs/sars-cov-2-genomes.fasta"
ALIGNMENT_MSA_OUTPUT = f"{ALIGNMENT_PROJECT_PATH}/Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa"
FIXTURE_GENERATOR_ARGV = [
    "python3",
    "Tests/Fixtures/alignment/create_sarscov2_alignment_fixture.py",
]
MAFFT_ALIGNMENT_ARGV = [
    "lungfish",
    "align",
    "mafft",
    ALIGNMENT_INPUT_FASTA,
    "--project",
    ALIGNMENT_PROJECT_PATH,
    "--output",
    ALIGNMENT_MSA_OUTPUT,
    "--name",
    "sars-cov-2-genomes-mafft",
    "--strategy",
    "auto",
    "--output-order",
    "input",
    "--sequence-type",
    "auto",
    "--adjust-direction",
    "off",
    "--symbols",
    "strict",
    "--threads",
    "2",
    "--format",
    "json",
]
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
    import shlex

    return " ".join(shlex.quote(part) for part in argv)


def reproducible_backfill_argv(args):
    argv = ["scripts/testing/write-analysis-fixture-provenance.py", "--root", "."]
    if args.created_at is not None:
        argv.extend(["--created-at", args.created_at])
    if args.overwrite:
        argv.append("--overwrite")
    return argv


def build_record(root, relative_fixture, metadata, created_at, executed_argv, overwrite_existing):
    if relative_fixture == "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish":
        return build_alignment_root_record(root, relative_fixture)
    if relative_fixture.endswith(".lungfishmsa"):
        return build_msa_record(root, relative_fixture)

    fixture_path = root / relative_fixture
    entries = file_entries(fixture_path)
    shell = shell_command(executed_argv)

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
        "reproducibleShellCommand": shell,
    }


def build_alignment_root_record(root, relative_fixture):
    fixture_path = root / relative_fixture
    entries = file_entries(fixture_path)
    source_fasta = "Tests/Fixtures/sarscov2/genome.fasta"
    source_path = root / source_fasta
    generator_command = shell_command(FIXTURE_GENERATOR_ARGV)
    mafft_command = shell_command(MAFFT_ALIGNMENT_ARGV)
    composite_command = f"{generator_command} && {mafft_command}"
    return {
        "argv": ["sh", "-c", composite_command],
        "createdAt": "2026-05-03T20:52:54Z",
        "exitStatus": 0,
        "files": entries,
        "input": file_reference(source_path, source_fasta),
        "options": {
            "derivedRecordPolicy": "deterministic synthetic derivatives from the local source fixture",
            "mafftAlignmentOutput": ALIGNMENT_MSA_OUTPUT,
            "outputDirectory": relative_fixture,
            "recordCount": 5,
            "sourceAccession": "MT192765.1",
            "sourceFasta": source_fasta,
            "workflowKind": "composite-e2e-fixture",
        },
        "output": output_reference(relative_fixture, entries),
        "reproducibleCommand": composite_command,
        "runtimeIdentity": {
            "condaEnvironment": "base",
            "containerImage": None,
            "executablePath": "python3",
            "operatingSystemVersion": "macOS-26.4.1-arm64-arm-64bit-Mach-O",
            "pythonVersion": "3.14.3",
        },
        "schemaVersion": 1,
        "stderr": None,
        "toolName": "create_sarscov2_alignment_fixture.py + lungfish align mafft",
        "toolVersion": "0.1.0+0.1.0",
        "wallTimeSeconds": 0.059105750027811155,
        "warnings": [
            "Records B-E are deterministic synthetic derivatives for end-to-end testing and are not biological observations."
        ],
        "workflowName": "sars-cov-2-alignment-e2e-fixture-generation",
        "workflowSteps": [
            {
                "argv": FIXTURE_GENERATOR_ARGV,
                "options": {
                    "outputDirectory": relative_fixture,
                    "recordCount": 5,
                    "sourceFasta": source_fasta,
                },
                "output": f"{relative_fixture}/Inputs/sars-cov-2-genomes.fasta",
                "reproducibleCommand": generator_command,
                "stepName": "generate-sars-cov-2-input-fixture",
                "toolName": "create_sarscov2_alignment_fixture.py",
                "workflowName": "sars-cov-2-alignment-fixture-generation",
            },
            {
                "argv": MAFFT_ALIGNMENT_ARGV,
                "options": {
                    "adjustDirection": "off",
                    "format": "json",
                    "name": "sars-cov-2-genomes-mafft",
                    "outputOrder": "input",
                    "sequenceType": "auto",
                    "strategy": "auto",
                    "symbols": "strict",
                    "threads": 2,
                },
                "output": ALIGNMENT_MSA_OUTPUT,
                "reproducibleCommand": mafft_command,
                "stepName": "align-sars-cov-2-input-with-mafft",
                "toolName": "lungfish align mafft",
                "workflowName": "multiple-sequence-alignment-mafft",
            },
        ],
    }


def build_msa_record(root, relative_fixture):
    fixture_path = root / relative_fixture
    require_msa_payload_files(fixture_path)
    entries = file_entries(fixture_path)
    output_path = relative_fixture
    source_original = "alignment/source.original"
    return {
        "argv": MAFFT_ALIGNMENT_ARGV,
        "createdAt": "2026-05-03T20:53:06Z",
        "exitStatus": 0,
        "externalToolInvocations": [
            {
                "argv": [
                    "mafft",
                    "--auto",
                    "--thread",
                    "2",
                    "--threadit",
                    "0",
                    "--inputorder",
                    "alignment/input.unaligned.fasta",
                ],
                "condaEnvironment": "mafft",
                "executablePath": "mafft",
                "exitStatus": 0,
                "name": "mafft",
                "reproducibleCommand": "mafft --auto --thread 2 --threadit 0 --inputorder alignment/input.unaligned.fasta > alignment/primary.aligned.fasta",
                "stderr": MAFFT_STDERR,
                "version": "7.526",
                "wallTimeSeconds": 1.7744510173797607,
            }
        ],
        "files": entries,
        "input": file_reference(fixture_path / source_original, source_original),
        "inputFiles": [file_reference(root / ALIGNMENT_INPUT_FASTA, ALIGNMENT_INPUT_FASTA)],
        "options": {
            "gapAlphabet": ["-", "."],
            "name": "sars-cov-2-genomes-mafft",
            "resolvedSourceFormat": "aligned-fasta",
            "sourceFormat": "aligned-fasta",
            "writeSQLiteIndex": True,
            "writeViewState": True,
        },
        "output": output_reference(relative_fixture, entries),
        "reproducibleCommand": shell_command(MAFFT_ALIGNMENT_ARGV),
        "runtimeIdentity": {
            "condaEnvironment": "base",
            "executablePath": "lungfish-cli",
            "operatingSystemVersion": "Version 26.4.1 (Build 25E253)",
        },
        "schemaVersion": 1,
        "stderr": MAFFT_STDERR,
        "toolName": "lungfish align mafft",
        "toolVersion": "0.1.0",
        "wallTimeSeconds": 1.7888590097427368,
        "warnings": [],
        "workflowName": "multiple-sequence-alignment-mafft",
    }


def file_reference(path, relative_path):
    if path.is_file():
        return {
            "checksumSHA256": file_entries_for_single(path)["checksumSHA256"],
            "fileSize": path.stat().st_size,
            "path": relative_path,
        }
    raise ValueError(f"missing required scientific input {relative_path}: {path}")


def require_msa_payload_files(fixture_path):
    for relative_path in REQUIRED_MSA_PAYLOAD_FILES:
        path = fixture_path / relative_path
        if not path.is_file():
            raise ValueError(f"missing required MAFFT payload file {relative_path}: {path}")


def file_entries_for_single(path):
    from fixture_provenance import sha256_file

    return {"checksumSHA256": sha256_file(path)}


def output_reference(relative_fixture, entries):
    size = directory_size(entries)
    return {
        "checksumSHA256": directory_checksum(entries),
        "fileSize": size,
        "path": relative_fixture,
        "size": size,
    }


MAFFT_STDERR = """nthread = 2
nthreadpair = 2
nthreadtb = 2
ppenalty_ex = 0
stacksize: 8176 kb
generating a scoring matrix for nucleotide (dist=200) ... done
Gap Penalty = -1.53, +0.00, +0.00



Making a distance matrix ..
\r    1 / 5 (thread    0)
done.

Constructing a UPGMA tree (efffree=0) ...
\r    0 / 5
done.

Progressive alignment 1/2...
\rSTEP     1 / 4 (thread    1) f\b\b\rSTEP     2 / 4 (thread    0) f\b\b\rSTEP     3 / 4 (thread    1) f\b\b\rSTEP     4 / 4 (thread    0) f\b\b
done.

Making a distance matrix from msa..
\r    0 / 5 (thread    0)
done.

Constructing a UPGMA tree (efffree=1) ...
\r    0 / 5
done.

Progressive alignment 2/2...
\rSTEP     1 / 4 (thread    1) f\b\b\rSTEP     2 / 4 (thread    0) f\b\b\rSTEP     3 / 4 (thread    1) f\b\b\rSTEP     4 / 4 (thread    0) f\b\b
done.

disttbfast (nuc) Version 7.526
alg=A, model=DNA200 (2), 1.53 (4.59), -0.00 (-0.00), noshift, amax=0.0
2 thread(s)


Strategy:
 FFT-NS-2 (Fast but rough)
 Progressive method (guide trees were built 2 times.)

If unsure which option to use, try 'mafft --auto input > output'.
For more information, see 'mafft --help', 'mafft --man' and the mafft page.

The default gap scoring scheme has been changed in version 7.110 (2013 Oct).
It tends to insert more gaps into gap-rich regions than previous versions.
To disable this change, add the --leavegappyregion option.

"""


def main():
    args = parse_args()
    root = args.root.resolve()
    created_at = args.created_at or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    executed_argv = reproducible_backfill_argv(args)
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

        try:
            record = build_record(root, relative_fixture, metadata, created_at, executed_argv, args.overwrite)
        except ValueError as error:
            print(error, file=sys.stderr)
            return 1
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
