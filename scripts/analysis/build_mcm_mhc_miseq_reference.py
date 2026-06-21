#!/usr/bin/env python3
"""Build the MCM MHC miSeq amplicon reference from IPD/NHP sources.

The workflow extracts workbook-listed MCM alleles from the full IPD/NHP
Mafa genomic FASTA, trims locus-family amplicons outside the PCR primer
binding sites, collapses duplicate amplicon sequences, and writes a
Lungfish-compatible MHC reference bundle plus QC/provenance sidecars.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import platform
import re
import shutil
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

import openpyxl


TOOL_NAME = "build-mcm-mhc-miseq-reference"
TOOL_VERSION = "2026-06-17.1"
DEFAULT_OUTPUT_DIR = Path("outputs/mcm-mhc-miseq-reference-20260617")
DEFAULT_BUNDLE_NAME = "MCM-MHC-miSeq-20260617.lungfishmhcref"
DEFAULT_REFERENCE_ID_PREFIX = "MCM_MHC_MiSeq"
DEFAULT_DEFINITION_ID = "mcm-mhc-miseq-20260617"
DEFAULT_ASSAY_ID = "MHC-exon2-miSeq"

MCM_PRIMARY_HAPLOTYPE_ALLELES: dict[str, dict[str, list[str]]] = {
    "MHC-A": {
        "M1": ["MCM_MHC_MiSeq_0068", "MCM_MHC_MiSeq_0129", "MCM_MHC_MiSeq_0079"],
        "M2": ["MCM_MHC_MiSeq_0068", "MCM_MHC_MiSeq_0129", "MCM_MHC_MiSeq_0145"],
        "M3": ["MCM_MHC_MiSeq_0068", "MCM_MHC_MiSeq_0127"],
        "M4": ["MCM_MHC_MiSeq_0069"],
        "M5": ["MCM_MHC_MiSeq_0099"],
        "M6": ["MCM_MHC_MiSeq_0103", "MCM_MHC_MiSeq_0070"],
        "M7": ["MCM_MHC_MiSeq_0061"],
    },
    "MHC-E": {
        "M1": ["MCM_MHC_MiSeq_0010", "MCM_MHC_MiSeq_0017"],
        "M2": ["MCM_MHC_MiSeq_0012"],
        "M3": ["MCM_MHC_MiSeq_0012", "MCM_MHC_MiSeq_0018", "MCM_MHC_MiSeq_0137"],
        "M4": ["MCM_MHC_MiSeq_0017", "MCM_MHC_MiSeq_0019"],
        "M5": ["MCM_MHC_MiSeq_0015", "MCM_MHC_MiSeq_0019"],
        "M6": ["MCM_MHC_MiSeq_0011", "MCM_MHC_MiSeq_0013", "MCM_MHC_MiSeq_0015"],
        "M7": ["MCM_MHC_MiSeq_0014", "MCM_MHC_MiSeq_0016"],
    },
    "MHC-B": {
        "M1": ["MCM_MHC_MiSeq_0073", "MCM_MHC_MiSeq_0065"],
        "M2": ["MCM_MHC_MiSeq_0136", "MCM_MHC_MiSeq_0135"],
        "M3": ["MCM_MHC_MiSeq_0063", "MCM_MHC_MiSeq_0096"],
        "M4": ["MCM_MHC_MiSeq_0074"],
        "M5": ["MCM_MHC_MiSeq_0095", "MCM_MHC_MiSeq_0107"],
        "M6": ["MCM_MHC_MiSeq_0125", "MCM_MHC_MiSeq_0097"],
        "M7": ["MCM_MHC_MiSeq_0143", "MCM_MHC_MiSeq_0101"],
    },
    "MHC-DR": {
        "M1": ["MCM_MHC_MiSeq_0169", "MCM_MHC_MiSeq_0166"],
        "M2": ["MCM_MHC_MiSeq_0164", "MCM_MHC_MiSeq_0165"],
        "M3": ["MCM_MHC_MiSeq_0170", "MCM_MHC_MiSeq_0167"],
        "M4": ["MCM_MHC_MiSeq_0174"],
        "M5": ["MCM_MHC_MiSeq_0175"],
        "M6": ["MCM_MHC_MiSeq_0168", "MCM_MHC_MiSeq_0176"],
        "M7": ["MCM_MHC_MiSeq_0005", "MCM_MHC_MiSeq_0021"],
    },
    "MHC-DQ": {
        "M1": ["MCM_MHC_MiSeq_0173"],
        "M2": ["MCM_MHC_MiSeq_0025"],
        "M3": ["MCM_MHC_MiSeq_0177", "MCM_MHC_MiSeq_0026"],
        "M4": ["MCM_MHC_MiSeq_0179", "MCM_MHC_MiSeq_0023"],
        "M5": ["MCM_MHC_MiSeq_0024", "MCM_MHC_MiSeq_0188"],
        "M6": ["MCM_MHC_MiSeq_0022"],
        "M7": ["MCM_MHC_MiSeq_0008", "MCM_MHC_MiSeq_0180"],
    },
    "MHC-DP": {
        "M1": ["MCM_MHC_MiSeq_0007", "MCM_MHC_MiSeq_0154"],
        "M2": ["MCM_MHC_MiSeq_0187", "MCM_MHC_MiSeq_0153"],
        "M3": ["MCM_MHC_MiSeq_0157"],
        "M4": ["MCM_MHC_MiSeq_0159"],
        "M5": ["MCM_MHC_MiSeq_0156"],
        "M6": ["MCM_MHC_MiSeq_0156"],
        "M7": ["MCM_MHC_MiSeq_0159"],
    },
}


@dataclass(frozen=True)
class PrimerScheme:
    family: str
    left: str
    right: str
    min_length: int
    max_length: int
    target_length: int
    max_mismatches: int


PRIMER_SCHEMES: dict[str, PrimerScheme] = {
    "class_i": PrimerScheme(
        family="class_i",
        left="GGGCTACGTGGACGACAC",
        right="CTACTACAACCAGAGCGA",
        min_length=140,
        max_length=160,
        target_length=156,
        max_mismatches=10,
    ),
    "DPA": PrimerScheme(
        family="DPA",
        left="ATAGACCAACAGGGGAGT",
        right="ACTCAGGCCACCAATGAT",
        min_length=168,
        max_length=176,
        target_length=173,
        max_mismatches=6,
    ),
    "DPB": PrimerScheme(
        family="DPB",
        left="CGTTTAACGGGACACAGC",
        right="TGACCCTGAAGCGCCGAG",
        min_length=184,
        max_length=196,
        target_length=192,
        max_mismatches=8,
    ),
    "DQA": PrimerScheme(
        family="DQA",
        left="GTTGCCTCTTGCGGTGTAAA",
        right="TACCGCTGCTACCAATGGTA",
        min_length=198,
        max_length=206,
        target_length=204,
        max_mismatches=6,
    ),
    "DQB": PrimerScheme(
        family="DQB",
        left="CCCGCAGAGGATTTCGTG",
        right="ACTGGAACAGCCAGAAGG",
        min_length=152,
        max_length=156,
        target_length=154,
        max_mismatches=4,
    ),
    "DRB": PrimerScheme(
        family="DRB",
        left="CCCCACAGCACGTTTCTT",
        right="ACAGTGCAGCGGCGAGGT",
        min_length=238,
        max_length=246,
        target_length=244,
        max_mismatches=10,
    ),
}

A_REGION_LOCI = {
    "A",
    "A1",
    "A2",
    "A3",
    "A4",
    "A5",
    "A6",
    "A8",
    "E",
    "F",
    "AG1",
    "AG2",
    "AG3",
    "AG4",
    "AG5",
    "AG6",
    "G",
    "I",
    "J",
    "K",
    "L",
    "N",
    "V",
    "W",
}
B_REGION_LOCI = {
    "B",
    "B02P",
    "B02Ps",
    "B10P",
    "B11L",
    "B14P",
    "B14Ps",
    "B16",
    "B17",
    "B19P",
    "B19Ps",
    "B21P",
    "B21Ps",
    "B22",
}


@dataclass
class WorkbookAllele:
    official: str
    accession: str
    haplotypes: tuple[str, ...]
    comment: str
    previous_name: str
    status: str
    row_number: int


@dataclass
class FastaRecord:
    header: str
    sequence: str

    @property
    def name(self) -> str:
        return self.header.split()[0]


@dataclass
class PrimerHit:
    start: int
    mismatches: int
    observed: str


@dataclass
class TrimResult:
    status: str
    method: str
    sequence: str
    start: int | None
    end: int | None
    family: str
    left_mismatches: int | None = None
    right_mismatches: int | None = None
    left_hits_at_threshold: int | None = None
    right_hits_at_threshold: int | None = None
    notes: str = ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workbook", required=True, type=Path)
    parser.add_argument("--ipd-fasta", required=True, type=Path)
    parser.add_argument("--template-fasta", required=True, type=Path)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--bundle-name", default=DEFAULT_BUNDLE_NAME)
    parser.add_argument("--reference-id-prefix", default=DEFAULT_REFERENCE_ID_PREFIX)
    parser.add_argument("--definition-id", default=DEFAULT_DEFINITION_ID)
    parser.add_argument("--assay-id", default=DEFAULT_ASSAY_ID)
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_descriptor(path: Path, role: str) -> dict[str, object]:
    return {
        "path": str(path.resolve()),
        "role": role,
        "sha256": sha256_file(path),
        "sizeBytes": path.stat().st_size,
    }


def read_fasta(path: Path) -> list[FastaRecord]:
    records: list[FastaRecord] = []
    header: str | None = None
    chunks: list[str] = []
    with path.open() as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            if line.startswith(">"):
                if header is not None:
                    records.append(FastaRecord(header, "".join(chunks).upper()))
                header = line[1:].strip()
                chunks = []
            else:
                chunks.append(re.sub(r"\s+", "", line).upper())
    if header is not None:
        records.append(FastaRecord(header, "".join(chunks).upper()))
    return records


def write_fasta(records: Iterable[tuple[str, str]], path: Path, width: int = 80) -> None:
    with path.open("w") as handle:
        for header, sequence in records:
            handle.write(f">{header}\n")
            for i in range(0, len(sequence), width):
                handle.write(f"{sequence[i:i + width]}\n")


def parse_haplotypes(value: object) -> tuple[str, ...]:
    if value is None:
        return tuple()
    parts = re.split(r"[,;/]+", str(value))
    return tuple(sorted({part.strip() for part in parts if part.strip()}, key=haplotype_sort_key))


def haplotype_sort_key(value: str) -> tuple[int, str]:
    match = re.fullmatch(r"M(\d+)", value.strip())
    if match:
        return (int(match.group(1)), value)
    return (999, value)


def read_workbook(path: Path) -> list[WorkbookAllele]:
    workbook = openpyxl.load_workbook(path, read_only=True, data_only=True)
    sheet = workbook.active
    rows: list[WorkbookAllele] = []
    for row_number, row in enumerate(sheet.iter_rows(min_row=2, values_only=True), start=2):
        if not row or row[0] is None:
            continue
        rows.append(
            WorkbookAllele(
                official=str(row[0]).strip(),
                accession=str(row[1]).strip() if row[1] is not None else "",
                haplotypes=parse_haplotypes(row[2]),
                comment=str(row[3]).strip() if row[3] is not None else "",
                previous_name=str(row[4]).strip() if row[4] is not None else "",
                status=str(row[5]).strip() if row[5] is not None else "",
                row_number=row_number,
            )
        )
    return rows


def locus_token(official: str) -> str:
    match = re.match(r"Mafa-([^*]+)", official)
    return match.group(1) if match else "unknown"


def canonical_locus(official: str) -> str:
    return f"MHC-{locus_token(official)}"


def haplotype_group(official: str) -> str:
    token = locus_token(official)
    if token in A_REGION_LOCI or token.startswith(("A", "AG", "E", "F", "G", "I", "J", "K", "L", "N", "V", "W")):
        return "MHC-A"
    if token in B_REGION_LOCI or token.startswith("B"):
        return "MHC-B"
    if token.startswith("DPA") or token.startswith("DPB"):
        return "MHC-DP"
    if token.startswith("DQA") or token.startswith("DQB"):
        return "MHC-DQ"
    if token.startswith("DRA") or token.startswith("DRB"):
        return "MHC-DR"
    return f"MHC-{token}"


def primer_family(official: str) -> str:
    token = locus_token(official)
    if token.startswith("DPA"):
        return "DPA"
    if token.startswith("DPB"):
        return "DPB"
    if token.startswith("DQA"):
        return "DQA"
    if token.startswith("DQB"):
        return "DQB"
    if token.startswith("DRB"):
        return "DRB"
    if token.startswith("DRA"):
        return "DRA"
    return "class_i"


def is_support_only_pseudogene(official: str) -> bool:
    token = locus_token(official)
    return (
        token.endswith("P")
        or token.endswith("Ps")
        or "pseudo" in token.lower()
        or token == "DRB9"
        or official.endswith("N")
    )


def evidence_class(official: str) -> str:
    if is_support_only_pseudogene(official):
        return "support_only_pseudogene_or_null"
    return "primary_expressed"


def evidence_weight(official: str) -> float:
    return 0.25 if is_support_only_pseudogene(official) else 1.0


def hamming_hits(sequence: str, primer: str, max_mismatches: int) -> list[PrimerHit]:
    length = len(primer)
    hits: list[PrimerHit] = []
    for start in range(0, len(sequence) - length + 1):
        observed = sequence[start : start + length]
        mismatches = sum(a != b for a, b in zip(observed, primer))
        if mismatches <= max_mismatches:
            hits.append(PrimerHit(start=start, mismatches=mismatches, observed=observed))
    return hits


def trim_by_primers(sequence: str, family: str) -> TrimResult:
    if family == "DRA":
        return TrimResult(
            status="not_genotyped",
            method="not_in_amplicon_panel",
            sequence="",
            start=None,
            end=None,
            family=family,
            notes="DRA is intentionally not genotyped in this amplicon panel because it has minimal useful variability.",
        )
    scheme = PRIMER_SCHEMES.get(family)
    if scheme is None:
        return TrimResult(
            status="unresolved",
            method="no_primer_scheme",
            sequence="",
            start=None,
            end=None,
            family=family,
            notes=f"No primer scheme is defined for family {family}.",
        )

    left_length = len(scheme.left)
    for threshold in range(0, scheme.max_mismatches + 1):
        left_hits = hamming_hits(sequence, scheme.left, threshold)
        right_hits = hamming_hits(sequence, scheme.right, threshold)
        candidate_pairs = [
            (left, right)
            for left in left_hits
            for right in right_hits
            if scheme.min_length <= right.start - (left.start + left_length) <= scheme.max_length
        ]
        if len(left_hits) == 1 and len(right_hits) == 1 and len(candidate_pairs) == 1:
            left, right = candidate_pairs[0]
            start = left.start + left_length
            end = right.start
            return TrimResult(
                status="trimmed",
                method="strict_unique_primer_sweep",
                sequence=sequence[start:end],
                start=start,
                end=end,
                family=family,
                left_mismatches=left.mismatches,
                right_mismatches=right.mismatches,
                left_hits_at_threshold=len(left_hits),
                right_hits_at_threshold=len(right_hits),
            )

    left_hits = hamming_hits(sequence, scheme.left, scheme.max_mismatches)
    right_hits = hamming_hits(sequence, scheme.right, scheme.max_mismatches)
    candidates: list[tuple[float, PrimerHit, PrimerHit]] = []
    for left in left_hits:
        for right in right_hits:
            length = right.start - (left.start + left_length)
            if scheme.min_length <= length <= scheme.max_length:
                length_penalty = abs(length - scheme.target_length) / 10.0
                score = left.mismatches + right.mismatches + length_penalty
                candidates.append((score, left, right))

    if candidates:
        candidates.sort(key=lambda item: (item[0], item[1].mismatches + item[2].mismatches, item[1].start, item[2].start))
        _, left, right = candidates[0]
        start = left.start + left_length
        end = right.start
        left_count = sum(hit.mismatches <= left.mismatches for hit in left_hits)
        right_count = sum(hit.mismatches <= right.mismatches for hit in right_hits)
        return TrimResult(
            status="trimmed",
            method="permissive_best_primer_pair",
            sequence=sequence[start:end],
            start=start,
            end=end,
            family=family,
            left_mismatches=left.mismatches,
            right_mismatches=right.mismatches,
            left_hits_at_threshold=left_count,
            right_hits_at_threshold=right_count,
            notes="Strict unique primer sweep failed; selected best in-family primer pair within expected amplicon length.",
        )

    return TrimResult(
        status="unresolved",
        method="no_primer_pair_in_expected_length",
        sequence="",
        start=None,
        end=None,
        family=family,
        notes="No primer pair was found within the expected amplicon length window.",
    )


def safe_value(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_,.:-]+", "_", value.strip()) or "NA"


def fasta_header(record_id: str, fields: dict[str, object]) -> str:
    pieces = [record_id]
    for key, value in fields.items():
        if isinstance(value, (list, tuple)):
            text = ",".join(str(item) for item in value)
        else:
            text = str(value)
        pieces.append(f"{key}={safe_value(text)}")
    return "|".join(pieces)


def write_tsv(path: Path, fieldnames: list[str], rows: Iterable[dict[str, object]]) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter="\t", extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in fieldnames})


def build_haplotype_definition(
    unique_rows: list[dict[str, object]],
    definition_id: str,
    assay_id: str,
) -> dict[str, object]:
    by_locus_haplotype: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))
    evidence_by_reference: dict[str, float] = {}
    for row in unique_rows:
        reference_id = str(row["reference_id"])
        loci = str(row["haplotype_groups"]).split(",")
        haplotypes = [part for part in str(row["haplotypes"]).split(",") if part]
        evidence_by_reference[reference_id] = float(row["max_evidence_weight"])
        for locus in loci:
            for haplotype in haplotypes:
                by_locus_haplotype[locus][haplotype].add(reference_id)

    locus_definitions = []
    for locus in sorted(by_locus_haplotype):
        hap_defs = []
        for haplotype in sorted(by_locus_haplotype[locus], key=haplotype_sort_key):
            alleles = sorted(by_locus_haplotype[locus][haplotype])
            hap_def = {
                "name": haplotype,
                "diagnosticAlleles": alleles,
                "evidenceWeights": {allele: evidence_by_reference[allele] for allele in alleles},
                "minimumMatches": 1,
            }
            primary = MCM_PRIMARY_HAPLOTYPE_ALLELES.get(locus, {}).get(haplotype, [])
            if primary:
                hap_def["primaryAlleles"] = [allele for allele in primary if allele in alleles]
            hap_defs.append(hap_def)
        locus_definitions.append(
            {
                "locus": locus,
                "sourceLocus": locus,
                "haplotypes": hap_defs,
            }
        )

    return {
        "id": definition_id,
        "assayID": assay_id,
        "displayName": "MCM MHC miSeq haplotype associations",
        "speciesName": "Mauritian cynomolgus macaque",
        "speciesCode": "MCM",
        "prefix": "MHC",
        "locusDefinitions": locus_definitions,
    }


def copy_source(path: Path, destination_dir: Path) -> dict[str, object]:
    destination_dir.mkdir(parents=True, exist_ok=True)
    destination = destination_dir / path.name
    shutil.copy2(path, destination)
    return {
        "path": str(destination.relative_to(destination_dir.parent)),
        "role": "build_source",
        "originalPath": str(path.resolve()),
    }


def directory_digest(path: Path) -> tuple[str, int, list[dict[str, object]]]:
    files: list[dict[str, object]] = []
    total_size = 0
    for item in sorted(p for p in path.rglob("*") if p.is_file()):
        rel = item.relative_to(path).as_posix()
        size = item.stat().st_size
        total_size += size
        files.append({"path": rel, "sha256": sha256_file(item), "sizeBytes": size})
    digest_input = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(digest_input).hexdigest(), total_size, files


def main() -> int:
    started = time.monotonic()
    started_wall = datetime.now(timezone.utc)
    args = parse_args()
    stderr_notes: list[str] = []

    try:
        for source_path in (args.workbook, args.ipd_fasta, args.template_fasta):
            if not source_path.exists():
                raise FileNotFoundError(source_path)

        output_dir = args.output_dir.resolve()
        if output_dir.exists():
            if not args.force:
                raise FileExistsError(f"Output directory exists; use --force: {output_dir}")
            shutil.rmtree(output_dir)
        output_dir.mkdir(parents=True)
        qc_dir = output_dir / "qc"
        qc_dir.mkdir()

        workbook_rows = read_workbook(args.workbook)
        full_records = read_fasta(args.ipd_fasta)
        template_records = read_fasta(args.template_fasta)
        full_by_name = {record.name: record for record in full_records}
        template_sequences = {record.sequence for record in template_records}

        extracted_full_fasta: list[tuple[str, str]] = []
        by_allele_fasta: list[tuple[str, str]] = []
        allele_qc_rows: list[dict[str, object]] = []
        missing_rows: list[dict[str, object]] = []
        trimmed_entries: list[dict[str, object]] = []

        for allele in workbook_rows:
            source_record = full_by_name.get(allele.official)
            family = primer_family(allele.official)
            locus = canonical_locus(allele.official)
            group = haplotype_group(allele.official)
            ev_class = evidence_class(allele.official)
            ev_weight = evidence_weight(allele.official)
            if source_record is None:
                status = "missing_from_ipd_fasta"
                notes = "No exact FASTA header matched the workbook official designation."
                if is_support_only_pseudogene(allele.official):
                    status = "support_only_missing_from_ipd_fasta"
                    notes = (
                        "No exact FASTA header matched the workbook official designation. "
                        "This pseudogene locus is support-only evidence and is not required for haplotype calls."
                    )
                missing_rows.append(
                    {
                        "official": allele.official,
                        "accession": allele.accession,
                        "haplotypes": ",".join(allele.haplotypes),
                        "locus": locus,
                        "haplotype_group": group,
                        "family": family,
                        "status": status,
                        "method": "",
                        "evidence_class": ev_class,
                        "evidence_weight": ev_weight,
                        "notes": notes,
                    }
                )
                allele_qc_rows.append(
                    {
                        "official": allele.official,
                        "accession": allele.accession,
                        "haplotypes": ",".join(allele.haplotypes),
                        "locus": locus,
                        "haplotype_group": group,
                        "family": family,
                        "status": status,
                        "evidence_class": ev_class,
                        "evidence_weight": ev_weight,
                        "notes": notes,
                    }
                )
                continue

            full_header = fasta_header(
                allele.official,
                {
                    "accession": allele.accession,
                    "haplotypes": allele.haplotypes,
                    "locus": locus,
                    "haplotype_group": group,
                    "evidence_class": ev_class,
                    "evidence_weight": ev_weight,
                    "source": "IPD-MHC_NHKIR_Mafa_genomic",
                },
            )
            extracted_full_fasta.append((full_header, source_record.sequence))

            trim = trim_by_primers(source_record.sequence, family)
            if (
                trim.status == "unresolved"
                and trim.method == "no_primer_pair_in_expected_length"
                and is_support_only_pseudogene(allele.official)
            ):
                trim = TrimResult(
                    status="support_only_untrimmed",
                    method="pseudogene_support_only_no_primer_pair",
                    sequence="",
                    start=None,
                    end=None,
                    family=family,
                    notes=(
                        "No primer pair was found within the expected amplicon length window. "
                        "This pseudogene locus is support-only evidence and is not required for haplotype calls."
                    ),
                )
            template_exact = trim.sequence in template_sequences if trim.sequence else False
            if trim.status == "trimmed":
                by_allele_header = fasta_header(
                    allele.official,
                    {
                        "accession": allele.accession,
                        "haplotypes": allele.haplotypes,
                        "source_locus": locus,
                        "haplotype_group": group,
                        "family": family,
                        "evidence_class": ev_class,
                        "evidence_weight": f"{ev_weight:.2f}",
                        "method": trim.method,
                    },
                )
                by_allele_fasta.append((by_allele_header, trim.sequence))
                trimmed_entries.append(
                    {
                        "official": allele.official,
                        "accession": allele.accession,
                        "haplotypes": allele.haplotypes,
                        "locus": locus,
                        "haplotype_group": group,
                        "family": family,
                        "evidence_class": ev_class,
                        "evidence_weight": ev_weight,
                        "sequence": trim.sequence,
                        "method": trim.method,
                        "template_exact": template_exact,
                    }
                )
            else:
                missing_rows.append(
                    {
                        "official": allele.official,
                        "accession": allele.accession,
                        "haplotypes": ",".join(allele.haplotypes),
                        "locus": locus,
                        "haplotype_group": group,
                        "family": family,
                        "status": trim.status,
                        "method": trim.method,
                        "evidence_class": ev_class,
                        "evidence_weight": ev_weight,
                        "notes": trim.notes,
                    }
                )

            allele_qc_rows.append(
                {
                    "official": allele.official,
                    "accession": allele.accession,
                    "haplotypes": ",".join(allele.haplotypes),
                    "locus": locus,
                    "haplotype_group": group,
                    "family": family,
                    "status": trim.status,
                    "method": trim.method,
                    "evidence_class": ev_class,
                    "evidence_weight": ev_weight,
                    "full_length_header": source_record.header,
                    "full_length_bp": len(source_record.sequence),
                    "trim_start_0based": trim.start if trim.start is not None else "",
                    "trim_end_0based_exclusive": trim.end if trim.end is not None else "",
                    "trimmed_bp": len(trim.sequence) if trim.sequence else "",
                    "left_primer_mismatches": trim.left_mismatches if trim.left_mismatches is not None else "",
                    "right_primer_mismatches": trim.right_mismatches if trim.right_mismatches is not None else "",
                    "left_hits_at_selected_threshold": trim.left_hits_at_threshold if trim.left_hits_at_threshold is not None else "",
                    "right_hits_at_selected_threshold": trim.right_hits_at_threshold if trim.right_hits_at_threshold is not None else "",
                    "template_exact_sequence": "yes" if template_exact else "no",
                    "notes": trim.notes,
                }
            )

        grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
        for entry in trimmed_entries:
            grouped[str(entry["sequence"])].append(entry)

        unique_rows: list[dict[str, object]] = []
        unique_fasta: list[tuple[str, str]] = []
        for index, sequence in enumerate(sorted(grouped), start=1):
            entries = grouped[sequence]
            reference_id = f"{args.reference_id_prefix}_{index:04d}"
            alleles = sorted(str(entry["official"]) for entry in entries)
            accessions = sorted({str(entry["accession"]) for entry in entries if entry["accession"]})
            haplotypes = sorted(
                {hap for entry in entries for hap in entry["haplotypes"]},
                key=haplotype_sort_key,
            )
            loci = sorted({str(entry["locus"]) for entry in entries})
            groups = sorted({str(entry["haplotype_group"]) for entry in entries})
            families = sorted({str(entry["family"]) for entry in entries})
            methods = sorted({str(entry["method"]) for entry in entries})
            evidence_classes = sorted({str(entry["evidence_class"]) for entry in entries})
            max_weight = max(float(entry["evidence_weight"]) for entry in entries)
            weight_sum = sum(float(entry["evidence_weight"]) for entry in entries)
            template_exact = any(bool(entry["template_exact"]) for entry in entries)
            row = {
                "reference_id": reference_id,
                "length": len(sequence),
                "loci": ",".join(loci),
                "haplotype_groups": ",".join(groups),
                "families": ",".join(families),
                "haplotypes": ",".join(haplotypes),
                "alleles": ",".join(alleles),
                "accessions": ",".join(accessions),
                "allele_count": len(entries),
                "evidence_classes": ",".join(evidence_classes),
                "max_evidence_weight": f"{max_weight:.2f}",
                "evidence_weight_sum": f"{weight_sum:.2f}",
                "methods": ",".join(methods),
                "template_exact_sequence": "yes" if template_exact else "no",
                "sha256": hashlib.sha256(sequence.encode()).hexdigest(),
            }
            unique_rows.append(row)
            unique_fasta.append(
                (
                    fasta_header(
                        reference_id,
                        {
                            "source_loci": loci,
                            "haplotype_groups": groups,
                            "haplotypes": haplotypes,
                            "alleles": alleles,
                            "accessions": accessions,
                            "length": len(sequence),
                            "evidence_classes": evidence_classes,
                            "max_evidence_weight": f"{max_weight:.2f}",
                            "evidence_weight_sum": f"{weight_sum:.2f}",
                        },
                    ),
                    sequence,
                )
            )

        unique_fasta_path = output_dir / "mcm_mhc_miseq_reference.trimmed.unique.fasta"
        by_allele_fasta_path = output_dir / "mcm_mhc_miseq_reference.trimmed.by_allele.fasta"
        full_fasta_path = output_dir / "mcm_mhc_full_length.extracted.fasta"
        write_fasta(unique_fasta, unique_fasta_path)
        write_fasta(by_allele_fasta, by_allele_fasta_path)
        write_fasta(extracted_full_fasta, full_fasta_path)

        unique_map_path = qc_dir / "unique_sequence_map.tsv"
        allele_qc_path = qc_dir / "allele_trim_qc.tsv"
        unresolved_path = qc_dir / "missing_or_unresolved.tsv"
        primer_scheme_path = qc_dir / "primer_schemes.json"
        summary_path = qc_dir / "summary.json"

        write_tsv(
            unique_map_path,
            [
                "reference_id",
                "length",
                "loci",
                "haplotype_groups",
                "families",
                "haplotypes",
                "alleles",
                "accessions",
                "allele_count",
                "evidence_classes",
                "max_evidence_weight",
                "evidence_weight_sum",
                "methods",
                "template_exact_sequence",
                "sha256",
            ],
            unique_rows,
        )
        write_tsv(
            allele_qc_path,
            [
                "official",
                "accession",
                "haplotypes",
                "locus",
                "haplotype_group",
                "family",
                "status",
                "method",
                "evidence_class",
                "evidence_weight",
                "full_length_header",
                "full_length_bp",
                "trim_start_0based",
                "trim_end_0based_exclusive",
                "trimmed_bp",
                "left_primer_mismatches",
                "right_primer_mismatches",
                "left_hits_at_selected_threshold",
                "right_hits_at_selected_threshold",
                "template_exact_sequence",
                "notes",
            ],
            allele_qc_rows,
        )
        write_tsv(
            unresolved_path,
            [
                "official",
                "accession",
                "haplotypes",
                "locus",
                "haplotype_group",
                "family",
                "status",
                "method",
                "evidence_class",
                "evidence_weight",
                "notes",
            ],
            missing_rows,
        )
        primer_scheme_path.write_text(
            json.dumps({key: scheme.__dict__ for key, scheme in PRIMER_SCHEMES.items()}, indent=2, sort_keys=True)
            + "\n"
        )

        haplotype_definition = build_haplotype_definition(unique_rows, args.definition_id, args.assay_id)
        haplotype_definition_path = output_dir / f"{args.definition_id}.lungfishhaplotypedef.json"
        haplotype_definition_path.write_text(json.dumps(haplotype_definition, indent=2, sort_keys=True) + "\n")

        bundle_path = output_dir / args.bundle_name
        bundle_path.mkdir()
        bundle_reference_path = bundle_path / unique_fasta_path.name
        shutil.copy2(unique_fasta_path, bundle_reference_path)
        haplotypes_dir = bundle_path / "haplotypes"
        haplotypes_dir.mkdir()
        bundle_definition_path = haplotypes_dir / haplotype_definition_path.name
        shutil.copy2(haplotype_definition_path, bundle_definition_path)
        sources_dir = bundle_path / "sources"
        source_files = [
            {
                "path": bundle_reference_path.name,
                "role": "reference_fasta",
                "originalPath": str(unique_fasta_path.resolve()),
            },
            {
                "path": f"haplotypes/{bundle_definition_path.name}",
                "role": "haplotype_definition_source",
                "originalPath": str(haplotype_definition_path.resolve()),
            },
            copy_source(args.workbook, sources_dir),
            copy_source(args.ipd_fasta, sources_dir),
            copy_source(args.template_fasta, sources_dir),
        ]
        manifest = {
            "schemaVersion": 1,
            "kind": "mhc-reference",
            "name": "MCM MHC miSeq reference 2026-06-17",
            "referenceFastaPath": bundle_reference_path.name,
            "haplotypeDefinitionPaths": [f"haplotypes/{bundle_definition_path.name}"],
            "defaultHaplotypeDefinitionID": args.definition_id,
            "sourceFiles": source_files,
            "metrics": {
                "referenceCount": len(unique_rows),
                "haplotypeDefinitionCount": 1,
            },
            "provenancePath": ".lungfish-provenance.json",
            "createdAt": started_wall.isoformat().replace("+00:00", "Z"),
        }
        (bundle_path / "mhc-reference.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

        summary = {
            "workflow": TOOL_NAME,
            "version": TOOL_VERSION,
            "workbookAlleles": len(workbook_rows),
            "ipdFastaRecords": len(full_records),
            "templateRecords": len(template_records),
            "fullLengthExtractedAlleles": len(extracted_full_fasta),
            "trimmedAlleles": len(trimmed_entries),
            "uniqueTrimmedSequences": len(unique_rows),
            "missingOrUnresolvedAlleles": len(missing_rows),
            "statusCounts": dict(Counter(str(row.get("status", "")) for row in allele_qc_rows)),
            "methodCounts": dict(Counter(str(row.get("method", "")) for row in allele_qc_rows if row.get("method"))),
            "familyCountsTrimmed": dict(Counter(str(entry["family"]) for entry in trimmed_entries)),
            "lengthCountsTrimmed": dict(Counter(str(len(str(entry["sequence"]))) for entry in trimmed_entries)),
            "haplotypeDefinitionLoci": sorted(
                {
                    group
                    for row in unique_rows
                    for group in str(row["haplotype_groups"]).split(",")
                    if group
                }
            ),
            "evidenceClassCountsTrimmed": dict(Counter(str(entry["evidence_class"]) for entry in trimmed_entries)),
            "uniqueTemplateExactSequences": sum(1 for row in unique_rows if row["template_exact_sequence"] == "yes"),
        }
        summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
        readme_path = output_dir / "README.md"
        readme_path.write_text(
            narrative_markdown(
                summary=summary,
                workbook=args.workbook,
                ipd_fasta=args.ipd_fasta,
                template_fasta=args.template_fasta,
                bundle_name=args.bundle_name,
            )
            + "\n"
        )

        output_files = [
            readme_path,
            unique_fasta_path,
            by_allele_fasta_path,
            full_fasta_path,
            unique_map_path,
            allele_qc_path,
            unresolved_path,
            primer_scheme_path,
            summary_path,
            haplotype_definition_path,
            bundle_path / "mhc-reference.json",
            bundle_reference_path,
            bundle_definition_path,
        ]
        bundle_digest, bundle_size, bundle_files = directory_digest(bundle_path)
        wall_time = time.monotonic() - started
        provenance = {
            "schemaVersion": 1,
            "workflowName": TOOL_NAME,
            "toolName": Path(__file__).name,
            "toolVersion": TOOL_VERSION,
            "argv": sys.argv,
            "reproducibleCommand": " ".join(shlex_quote(part) for part in sys.argv),
            "startedAt": started_wall.isoformat().replace("+00:00", "Z"),
            "completedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "wallTimeSeconds": wall_time,
            "exitStatus": 0,
            "stderr": "\n".join(stderr_notes),
            "runtime": {
                "python": sys.version,
                "executable": sys.executable,
                "platform": platform.platform(),
                "openpyxl": openpyxl.__version__,
                "condaPrefix": os.environ.get("CONDA_PREFIX", ""),
                "container": os.environ.get("container", ""),
            },
            "options": {
                "workbook": str(args.workbook.resolve()),
                "ipdFasta": str(args.ipd_fasta.resolve()),
                "templateFasta": str(args.template_fasta.resolve()),
                "outputDir": str(output_dir),
                "bundleName": args.bundle_name,
                "referenceIdPrefix": args.reference_id_prefix,
                "definitionID": args.definition_id,
                "assayID": args.assay_id,
                "force": args.force,
                "defaults": {
                    "outputDir": str(DEFAULT_OUTPUT_DIR),
                    "bundleName": DEFAULT_BUNDLE_NAME,
                    "referenceIdPrefix": DEFAULT_REFERENCE_ID_PREFIX,
                    "definitionID": DEFAULT_DEFINITION_ID,
                    "assayID": DEFAULT_ASSAY_ID,
                },
            },
            "inputs": [
                file_descriptor(args.workbook, "haplotype_workbook"),
                file_descriptor(args.ipd_fasta, "full_ipd_fasta"),
                file_descriptor(args.template_fasta, "trimmed_template_fasta"),
            ],
            "outputs": [file_descriptor(path, "output_file") for path in output_files if path.exists()]
            + [
                {
                    "path": str(bundle_path.resolve()),
                    "role": "lungfish_mhc_reference_bundle",
                    "sha256": bundle_digest,
                    "sizeBytes": bundle_size,
                    "fileCount": len(bundle_files),
                }
            ],
            "qcSummary": summary,
            "primerSchemes": {key: scheme.__dict__ for key, scheme in PRIMER_SCHEMES.items()},
            "bundleDirectoryManifest": bundle_files,
        }
        provenance_path = output_dir / ".lungfish-provenance.json"
        provenance_path.write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
        shutil.copy2(provenance_path, bundle_path / ".lungfish-provenance.json")
        (output_dir / "PROVENANCE.md").write_text(provenance_markdown(provenance) + "\n")

        # Recompute bundle digest after copying provenance into the bundle.
        bundle_digest, bundle_size, bundle_files = directory_digest(bundle_path)
        provenance["outputs"][-1].update(
            {
                "sha256": bundle_digest,
                "sizeBytes": bundle_size,
                "fileCount": len(bundle_files),
            }
        )
        provenance["bundleDirectoryManifest"] = bundle_files
        provenance_path.write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
        shutil.copy2(provenance_path, bundle_path / ".lungfish-provenance.json")
        (output_dir / "PROVENANCE.md").write_text(provenance_markdown(provenance) + "\n")

        print(json.dumps(summary, indent=2, sort_keys=True))
        return 0
    except Exception as error:
        wall_time = time.monotonic() - started
        stderr_notes.append(f"{type(error).__name__}: {error}")
        try:
            output_dir = args.output_dir.resolve()
            output_dir.mkdir(parents=True, exist_ok=True)
            failure_provenance = {
                "schemaVersion": 1,
                "workflowName": TOOL_NAME,
                "toolName": Path(__file__).name,
                "toolVersion": TOOL_VERSION,
                "argv": sys.argv,
                "reproducibleCommand": " ".join(shlex_quote(part) for part in sys.argv),
                "startedAt": started_wall.isoformat().replace("+00:00", "Z"),
                "completedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "wallTimeSeconds": wall_time,
                "exitStatus": 1,
                "stderr": "\n".join(stderr_notes),
                "runtime": {
                    "python": sys.version,
                    "executable": sys.executable,
                    "platform": platform.platform(),
                    "openpyxl": openpyxl.__version__,
                },
            }
            (output_dir / ".lungfish-provenance.json").write_text(
                json.dumps(failure_provenance, indent=2, sort_keys=True) + "\n"
            )
        finally:
            print(f"{type(error).__name__}: {error}", file=sys.stderr)
        return 1


def shlex_quote(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_./:=@%+-]+", value):
        return value
    return "'" + value.replace("'", "'\"'\"'") + "'"


def provenance_markdown(provenance: dict[str, object]) -> str:
    options = provenance["options"]
    qc = provenance["qcSummary"]
    inputs = provenance["inputs"]
    outputs = provenance["outputs"]
    lines = [
        f"# {provenance['workflowName']} Provenance",
        "",
        f"- Tool version: `{provenance['toolVersion']}`",
        f"- Command: `{provenance['reproducibleCommand']}`",
        f"- Exit status: `{provenance['exitStatus']}`",
        f"- Wall time seconds: `{provenance['wallTimeSeconds']:.3f}`",
        f"- Runtime executable: `{provenance['runtime']['executable']}`",
        "",
        "## Options",
        "",
        "```json",
        json.dumps(options, indent=2, sort_keys=True),
        "```",
        "",
        "## QC Summary",
        "",
        "```json",
        json.dumps(qc, indent=2, sort_keys=True),
        "```",
        "",
        "## Inputs",
        "",
    ]
    for item in inputs:
        lines.append(f"- `{item['path']}` ({item['role']}): sha256 `{item['sha256']}`, {item['sizeBytes']} bytes")
    lines.extend(["", "## Outputs", ""])
    for item in outputs:
        lines.append(f"- `{item['path']}` ({item['role']}): sha256 `{item['sha256']}`, {item['sizeBytes']} bytes")
    return "\n".join(lines)


def narrative_markdown(
    summary: dict[str, object],
    workbook: Path,
    ipd_fasta: Path,
    template_fasta: Path,
    bundle_name: str,
) -> str:
    return f"""# MCM MHC miSeq Reference Build

This folder contains a reproducible build of a Mauritian cynomolgus macaque
MHC miSeq amplicon reference database. The primary deliverable is a collapsed
FASTA of unique primer-trimmed amplicons for genotyping, plus mapping/QC files
that preserve the original MCM allele, accession, and haplotype associations.
The same FASTA and mapping tables are intended to be referenced by the AI
haplotyping knowledge pack.

## Original Inputs

The workflow used these original source files from `~/Downloads`:

- `{workbook.name}`
  - Workbook of MCM MHC official designations, accession numbers, and M1-M7
    haplotype assignments.
- `{ipd_fasta.name}`
  - Full IPD/NHP Mafa genomic FASTA library used to retrieve the full-length
    sequences for workbook-listed MCM alleles.
- `{template_fasta.name}`
  - Existing trimmed miSeq amplicon FASTA used as the template for expected
    amplicon boundaries and duplicate/multiple-haplotype representation.

Copies of the three original inputs are embedded in:

`{bundle_name}/sources/`

## What The Build Does

1. Reads the MCM workbook and treats the `Official designation` column as the
   authoritative key for extracting sequences from the full IPD FASTA.
2. Extracts all exact workbook allele matches from the full IPD FASTA into
   `mcm_mhc_full_length.extracted.fasta`.
3. Trims extracted sequences to the sequenced amplicon region by removing the
   primer-binding flanks.
4. Searches primer flanks conservatively first, requiring one forward and one
   reverse hit in the expected order and expected amplicon length window.
5. If strict unique primer matching fails, uses a permissive best-pair fallback
   only when a pair falls inside the expected locus-family amplicon length
   window. These cases are flagged in QC.
6. Collapses identical trimmed amplicon sequences so each sequence appears once
   in the primary reference FASTA, with header fields listing all associated
   loci, haplotypes, alleles, and accessions.
7. Writes a Lungfish `.lungfishmhcref` bundle containing the collapsed FASTA,
   a haplotype-definition JSON, the copied sources, and provenance.

Haplotype definition grouping follows Figure 1 of Karl et al. 2023
(`PMID: 36854669`): yellow class I A-region genes/pseudogenes are grouped as
`MHC-A`; orange class I B-region genes/pseudogenes are grouped as `MHC-B`;
class II genes are grouped as `MHC-DP`, `MHC-DQ`, or `MHC-DR`. The original
gene-level loci remain in FASTA headers and QC tables as `source_loci`.

Sequence headers also carry evidence-strength fields. Putatively expressed
genes are marked `evidence_classes=primary_expressed` with weight `1.00`.
Pseudogenes and null/nonfunctioning alleles are marked
`support_only_pseudogene_or_null` with weight `0.25`; these can improve
haplotype evidence when present but are not intended to outweigh expressed
gene evidence.

## Primary Outputs

- `mcm_mhc_miseq_reference.trimmed.unique.fasta`
  - Primary reference database FASTA for genotyping.
  - Contains {summary["uniqueTrimmedSequences"]} unique trimmed amplicon sequences.
  - Headers use stable IDs like `MCM_MHC_MiSeq_0001` and include locus,
    haplotype, allele, accession, and length metadata.
- `mcm_mhc_miseq_reference.trimmed.by_allele.fasta`
  - Non-collapsed allele-level trimmed FASTA.
  - Contains one record per successfully trimmed workbook allele.
- `mcm_mhc_full_length.extracted.fasta`
  - Full-length source sequences extracted from the IPD FASTA for the workbook
    alleles that had exact header matches.
- `{bundle_name}/`
  - Lungfish MHC reference bundle containing the primary FASTA, haplotype
    definition JSON, source copies, manifest, and provenance.
- `mcm-mhc-miseq-20260617.lungfishhaplotypedef.json`
  - Haplotype association file derived from the collapsed reference IDs.

## QC And Mapping Outputs

- `qc/summary.json`
  - Machine-readable run summary.
- `qc/allele_trim_qc.tsv`
  - Per-workbook-allele extraction, trim, primer mismatch, primer-hit-count,
    length, and template-concordance audit table.
- `qc/unique_sequence_map.tsv`
  - Mapping from collapsed reference IDs to source alleles, accessions,
    haplotypes, source loci, grouped haplotype loci, evidence classes,
    evidence weights, sequence hashes, and template exact-match status.
- `qc/missing_or_unresolved.tsv`
  - Alleles from the workbook that were not included in the trimmed reference
    FASTA because the source FASTA lacked an exact official-designation match
    or because no trustworthy primer-bounded amplicon was found.
- `qc/primer_schemes.json`
  - Primer-flank motifs, expected length windows, and mismatch ceilings used
    by the build.

## Build Summary

- Workbook alleles: {summary["workbookAlleles"]}
- Full-length alleles extracted from IPD FASTA: {summary["fullLengthExtractedAlleles"]}
- Successfully trimmed alleles: {summary["trimmedAlleles"]}
- Unique collapsed trimmed reference sequences: {summary["uniqueTrimmedSequences"]}
- Missing or unresolved workbook alleles: {summary["missingOrUnresolvedAlleles"]}
- Strict unique primer-trimmed alleles: {summary["methodCounts"].get("strict_unique_primer_sweep", 0)}
- Permissive best-primer-pair trimmed alleles: {summary["methodCounts"].get("permissive_best_primer_pair", 0)}
- Haplotype definition loci: {", ".join(summary["haplotypeDefinitionLoci"])}

Trimmed family counts:

- class I-like loci, including A, AG, B, E, F, G, I, J, K, and L: {summary["familyCountsTrimmed"].get("class_i", 0)}
- DPA: {summary["familyCountsTrimmed"].get("DPA", 0)}
- DPB: {summary["familyCountsTrimmed"].get("DPB", 0)}
- DQA: {summary["familyCountsTrimmed"].get("DQA", 0)}
- DQB: {summary["familyCountsTrimmed"].get("DQB", 0)}
- DRB: {summary["familyCountsTrimmed"].get("DRB", 0)}

The primary FASTA includes class I-like MHC-K and MHC-L sequences even though
those loci were not represented in the supplied trimmed template FASTA.

## Known Gaps

The following rows are intentionally not present in the primary trimmed FASTA
and are listed in `qc/missing_or_unresolved.tsv`:

- 13 workbook alleles had no exact official-designation header in
  `{ipd_fasta.name}`. Several of these are pseudogene/support-only rows; those
  can improve evidence for a haplotype call when present but are not required
  to make the call.
- 7 DRA alleles were present in the IPD FASTA but are intentionally excluded
  because DRA is not genotyped in this amplicon panel; it has minimal useful
  variability for these calls.
- 5 DRB9 alleles were present in the IPD FASTA but no primer pair was found
  within the expected DRB amplicon length window. DRB9 is a pseudogene and is
  treated as support-only evidence, not a required haplotype-call marker.

The required haplotype-call reference is therefore the trimmed amplicon FASTA;
support-only pseudogene rows are audited separately when missing or untrimmed.

## Provenance

Reproducibility provenance is written to:

- `.lungfish-provenance.json`
- `PROVENANCE.md`
- `{bundle_name}/.lungfish-provenance.json`

The provenance includes the executed script name/version, exact argv and
reproducible shell command, resolved options and defaults, runtime identity,
input and output paths, checksums, file sizes, exit status, wall time, and QC
summary.
"""


if __name__ == "__main__":
    raise SystemExit(main())
