#!/usr/bin/env python3
"""Create the SARS-CoV-2 MSA end-to-end fixture input project.

This script intentionally derives all records from the local SARS-CoV-2
reference fixture so the artifact can be regenerated without network access.
The non-source records are deterministic synthetic derivatives for importer
and alignment testing only; they are not biological observations.
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import json
import os
import platform
import shutil
import sys
import time
from pathlib import Path


SCRIPT_VERSION = "0.1.0"
SOURCE_ACCESSION = "MT192765.1"
OUTPUT_NAME = "sarscov2-mafft-e2e.lungfish"


def main() -> int:
    started = time.monotonic()
    script_path = Path(__file__).resolve()
    repo_root = script_path.parents[3]
    source_fasta = repo_root / "Tests" / "Fixtures" / "sarscov2" / "genome.fasta"
    output_root = script_path.parent / OUTPUT_NAME
    inputs_dir = output_root / "Inputs"
    alignments_dir = output_root / "Multiple Sequence Alignments"

    if output_root.exists():
        shutil.rmtree(output_root)
    inputs_dir.mkdir(parents=True)
    alignments_dir.mkdir(parents=True)

    source_header, source_sequence = read_fasta(source_fasta)
    records = build_records(source_sequence)

    fasta_url = inputs_dir / "sars-cov-2-genomes.fasta"
    metadata_url = inputs_dir / "source-metadata.tsv"
    readme_url = output_root / "README.md"

    fasta_url.write_text(format_fasta(records), encoding="utf-8")
    metadata_url.write_text(format_metadata(records), encoding="utf-8")
    readme_url.write_text(
        format_readme(source_fasta=source_fasta, source_header=source_header),
        encoding="utf-8",
    )

    generated_paths = [
        fasta_url,
        metadata_url,
        readme_url,
    ]
    files = {
        relative_to_output(path, output_root): file_record(path)
        for path in generated_paths
    }
    output_digest = hashlib.sha256(
        "\n".join(
            f"{relative_path}\t{record['checksumSHA256']}\t{record['fileSize']}"
            for relative_path, record in sorted(files.items())
        ).encode("utf-8")
    ).hexdigest()

    argv = [sys.executable, str(script_path)]
    provenance = {
        "schemaVersion": 1,
        "workflowName": "sars-cov-2-alignment-fixture-generation",
        "toolName": "create_sarscov2_alignment_fixture.py",
        "toolVersion": SCRIPT_VERSION,
        "argv": argv,
        "reproducibleCommand": shell_join(argv),
        "options": {
            "sourceFasta": str(source_fasta),
            "sourceAccession": SOURCE_ACCESSION,
            "outputDirectory": str(output_root),
            "recordCount": len(records),
            "derivedRecordPolicy": "deterministic synthetic derivatives from the local source fixture",
        },
        "runtimeIdentity": {
            "executablePath": sys.executable,
            "pythonVersion": platform.python_version(),
            "operatingSystemVersion": platform.platform(),
            "processIdentifier": os.getpid(),
            "condaEnvironment": os.environ.get("CONDA_DEFAULT_ENV"),
            "containerImage": os.environ.get("LUNGFISH_CONTAINER_IMAGE"),
        },
        "input": file_record(source_fasta),
        "output": {
            "path": str(output_root),
            "checksumSHA256": output_digest,
            "fileSize": sum(record["fileSize"] for record in files.values()),
        },
        "files": files,
        "exitStatus": 0,
        "wallTimeSeconds": max(0.0, time.monotonic() - started),
        "warnings": [
            "Records B-E are deterministic synthetic derivatives for end-to-end testing and are not biological observations."
        ],
        "stderr": None,
        "createdAt": _dt.datetime.now(_dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
    }
    (output_root / ".lungfish-provenance.json").write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    print(output_root)
    return 0


def read_fasta(url: Path) -> tuple[str, str]:
    header: str | None = None
    parts: list[str] = []
    for raw_line in url.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith(">"):
            if header is not None:
                raise ValueError(f"Expected one FASTA record in {url}")
            header = line[1:].strip()
            continue
        parts.append(line)
    if header is None or not parts:
        raise ValueError(f"Missing FASTA record in {url}")
    return header, "".join(parts).upper()


def build_records(source_sequence: str) -> list[dict[str, object]]:
    specs = [
        {
            "sample_id": "sarscov2_fixture_A_source",
            "description": "source sequence from the local SARS-CoV-2 fixture",
            "edits": [],
        },
        {
            "sample_id": "sarscov2_fixture_B_snp_set",
            "description": "deterministic synthetic derivative with a compact SNP set",
            "edits": [
                ("sub", 241, "T"),
                ("sub", 3037, "T"),
                ("sub", 14408, "T"),
                ("sub", 23403, "G"),
                ("sub", 28881, "A"),
                ("sub", 28882, "A"),
                ("sub", 28883, "C"),
            ],
        },
        {
            "sample_id": "sarscov2_fixture_C_short_deletion",
            "description": "deterministic synthetic derivative with a short deletion and two SNPs",
            "edits": [
                ("sub", 8782, "T"),
                ("del", 11288, 6),
                ("sub", 28144, "C"),
            ],
        },
        {
            "sample_id": "sarscov2_fixture_D_insertion",
            "description": "deterministic synthetic derivative with one short insertion and three SNPs",
            "edits": [
                ("ins", 22204, "AAT"),
                ("sub", 23063, "T"),
                ("sub", 23604, "A"),
                ("sub", 25563, "T"),
            ],
        },
        {
            "sample_id": "sarscov2_fixture_E_mixed_variation",
            "description": "deterministic synthetic derivative with mixed SNP, deletion, and insertion edits",
            "edits": [
                ("sub", 670, "T"),
                ("sub", 3267, "T"),
                ("sub", 10029, "T"),
                ("del", 21765, 9),
                ("sub", 22995, "A"),
                ("sub", 26767, "T"),
                ("ins", 28270, "TT"),
            ],
        },
    ]

    records: list[dict[str, object]] = []
    for spec in specs:
        sequence, metadata = apply_edits(source_sequence, spec["edits"])
        records.append(
            {
                "sample_id": spec["sample_id"],
                "description": spec["description"],
                "sequence": sequence,
                "substitutions": metadata["substitutions"],
                "deletions": metadata["deletions"],
                "insertions": metadata["insertions"],
                "length": len(sequence),
                "checksum_sha256": hashlib.sha256(sequence.encode("utf-8")).hexdigest(),
            }
        )
    return records


def apply_edits(
    source_sequence: str,
    edits: list[tuple[str, int, str | int]],
) -> tuple[str, dict[str, list[str]]]:
    sequence = list(source_sequence)
    substitutions: list[str] = []
    deletions: list[str] = []
    insertions: list[str] = []

    for kind, position, value in sorted(edits, key=lambda item: item[1], reverse=True):
        if position < 1 or position > len(source_sequence):
            raise ValueError(f"Edit position {position} is outside the source sequence")
        index = position - 1
        if kind == "sub":
            preferred = str(value).upper()
            old = sequence[index].upper()
            new = preferred if preferred != old else alternate_base(old)
            sequence[index] = new
            substitutions.append(f"{old}{position}{new}")
        elif kind == "del":
            length = int(value)
            if length < 1 or position + length - 1 > len(source_sequence):
                raise ValueError(f"Deletion {position}:{length} is outside the source sequence")
            deleted = "".join(sequence[index : index + length])
            del sequence[index : index + length]
            deletions.append(f"{position}-{position + length - 1}del{deleted}")
        elif kind == "ins":
            inserted = str(value).upper()
            sequence[position:position] = list(inserted)
            insertions.append(f"{position}_{position + 1}ins{inserted}")
        else:
            raise ValueError(f"Unsupported edit kind: {kind}")

    return (
        "".join(sequence),
        {
            "substitutions": sorted(substitutions, key=coordinate_from_edit),
            "deletions": sorted(deletions, key=coordinate_from_edit),
            "insertions": sorted(insertions, key=coordinate_from_edit),
        },
    )


def alternate_base(base: str) -> str:
    return {
        "A": "C",
        "C": "T",
        "G": "A",
        "T": "G",
        "N": "A",
    }.get(base.upper(), "A")


def coordinate_from_edit(edit: str) -> int:
    digits = []
    for char in edit:
        if char.isdigit():
            digits.append(char)
        elif digits:
            break
    return int("".join(digits)) if digits else 0


def format_fasta(records: list[dict[str, object]]) -> str:
    output: list[str] = []
    for record in records:
        output.append(f">{record['sample_id']}")
        output.extend(wrap(str(record["sequence"]), width=80))
    return "\n".join(output) + "\n"


def format_metadata(records: list[dict[str, object]]) -> str:
    columns = [
        "sample_id",
        "source_accession",
        "source",
        "description",
        "substitutions",
        "deletions",
        "insertions",
        "length",
        "checksum_sha256",
    ]
    lines = ["\t".join(columns)]
    for record in records:
        lines.append(
            "\t".join(
                [
                    str(record["sample_id"]),
                    SOURCE_ACCESSION,
                    "Tests/Fixtures/sarscov2/genome.fasta",
                    str(record["description"]),
                    ";".join(record["substitutions"]) or ".",
                    ";".join(record["deletions"]) or ".",
                    ";".join(record["insertions"]) or ".",
                    str(record["length"]),
                    str(record["checksum_sha256"]),
                ]
            )
        )
    return "\n".join(lines) + "\n"


def format_readme(source_fasta: Path, source_header: str) -> str:
    return f"""# SARS-CoV-2 MAFFT End-to-End Fixture

This fixture is a small Lungfish project-style artifact used for testing the
MAFFT-backed multiple-sequence alignment workflow.

## Inputs

- `Inputs/sars-cov-2-genomes.fasta`: five SARS-CoV-2 genome records.
- `Inputs/source-metadata.tsv`: source and edit metadata for each record.

The first FASTA record is copied from `{source_fasta}`:

`>{source_header}`

Records B-E are deterministic synthetic derivatives of that local source
sequence. They exist only to exercise alignment, import, viewer, and
provenance paths; they are not biological observations or lineage labels.

## Generated Outputs

`Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa` is created
by running `lungfish align mafft` against the input FASTA. The native MSA bundle
contains its own `.lungfish-provenance.json` with the MAFFT command, runtime,
input checksums, output checksums, exit status, and wall time.
"""


def wrap(sequence: str, width: int) -> list[str]:
    return [sequence[index : index + width] for index in range(0, len(sequence), width)]


def file_record(url: Path) -> dict[str, object]:
    data = url.read_bytes()
    return {
        "path": str(url),
        "checksumSHA256": hashlib.sha256(data).hexdigest(),
        "fileSize": len(data),
    }


def relative_to_output(path: Path, output_root: Path) -> str:
    return path.relative_to(output_root).as_posix()


def shell_join(argv: list[str]) -> str:
    return " ".join(shell_escape(arg) for arg in argv)


def shell_escape(value: str) -> str:
    if value and all(char.isalnum() or char in "-_./:=" for char in value):
        return value
    return "'" + value.replace("'", "'\\''") + "'"


if __name__ == "__main__":
    raise SystemExit(main())
