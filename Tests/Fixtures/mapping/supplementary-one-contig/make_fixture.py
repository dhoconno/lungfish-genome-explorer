#!/usr/bin/env python3
"""Rebuilds the supplementary-one-contig fixture, the files beside this script.

Usage: python3 make_fixture.py <this fixture folder> <empty scratch folder>

The BAM has one reference sequence, one read group with a sample (SM), 10
primary mapped reads, 2 supplementary records and 1 unmapped read. It is made
with samtools and every count is checked here before a file is kept. The scratch
folder holds the SAM text and the unsorted BAM, and both are deleted at the end
(an alignment lives as sorted, indexed BAM, never as SAM). samtools comes from
the managed environment unless LUNGFISH_SAMTOOLS names another one.
"""
import json
import os
import random
import re
import shutil
import sqlite3
import statistics
import subprocess
import sys
from pathlib import Path

SAMTOOLS = os.environ.get("LUNGFISH_SAMTOOLS", "/Users/dho/.lungfish/conda/envs/samtools/bin/samtools")
CONTIG = "fixture1"
CONTIG_LENGTH = 1000
READ_LENGTH = 100
READ_GROUP = "rg1"
SAMPLE = "sample1"
TRACK_ID = "fixture-track"
RESULT_BAM = "fixture.sorted.bam"
VIEWER_BUNDLE = "fixture.lungfishref"
# Where the import saw the result's BAM. The folder is gone on every other Mac, as it is
# in a project that was moved or cloned, so the viewport matches the last two components.
ORIGINAL_SOURCE_PATH = "/Users/Shared/lungfish-fixtures/supplementary-one-contig/" + RESULT_BAM
PRIMARY_EXCLUSION_FLAGS = "UNMAP,SECONDARY,SUPPLEMENTARY,QCFAIL,DUP"

# The tables of AlignmentMetadataDatabase.createSchema, in the same order.
SCHEMA = """
CREATE TABLE IF NOT EXISTS file_info (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS read_groups (id TEXT PRIMARY KEY, sample TEXT, library TEXT, platform TEXT, platform_unit TEXT, center TEXT, description TEXT);
CREATE TABLE IF NOT EXISTS chromosome_stats (chromosome TEXT PRIMARY KEY, length INTEGER NOT NULL, mapped_reads INTEGER NOT NULL, unmapped_reads INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_chromstats_mapped ON chromosome_stats(mapped_reads DESC);
CREATE TABLE IF NOT EXISTS flag_stats (category TEXT PRIMARY KEY, qc_pass INTEGER NOT NULL, qc_fail INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS program_records (id TEXT PRIMARY KEY, name TEXT, version TEXT, command_line TEXT, prev_program TEXT);
CREATE TABLE IF NOT EXISTS provenance (step_order INTEGER PRIMARY KEY, tool TEXT NOT NULL, subcommand TEXT, version TEXT, command TEXT NOT NULL, timestamp TEXT, input_file TEXT, output_file TEXT, exit_code INTEGER, duration REAL, parent_step INTEGER REFERENCES provenance(step_order));
"""


def samtools(*arguments):
    completed = subprocess.run([SAMTOOLS, *arguments], check=True, capture_output=True, text=True)
    return completed.stdout


def normalize_flagstat_category(raw):
    """The same rule as AlignmentMetadataDatabase.normalizeFlagstatCategory."""
    category = raw
    if "(" in category:
        note = category[category.index("("):]
        if "%" in note or "n/a" in note.lower():
            category = category[:category.index("(")].strip()
    if category == "in total" or category.startswith("in total "):
        category = "total"
    return category


def sam_text(reference, rng):
    """Header plus 13 records: 10 primary mapped, 2 supplementary, 1 unmapped."""
    swap = {"A": "C", "C": "G", "G": "T", "T": "A"}

    def mutate(sequence, count):
        bases = list(sequence)
        step = len(bases) // (count + 1) if count else 0
        for index in range(1, count + 1):
            bases[index * step] = swap[bases[index * step]]
        return "".join(bases)

    lines = [
        "@HD\tVN:1.6\tSO:coordinate",
        f"@SQ\tSN:{CONTIG}\tLN:{CONTIG_LENGTH}",
        f"@RG\tID:{READ_GROUP}\tSM:{SAMPLE}\tPL:ILLUMINA",
        "@PG\tID:make_fixture\tPN:make_fixture.py\tVN:1\tCL:python3 make_fixture.py",
    ]
    quality = "I" * READ_LENGTH
    mismatches = {3: 2, 7: 1}
    quality_of = {9: 30, 10: 30}
    for number in range(1, 11):
        start = 1 + 90 * (number - 1)
        sequence = mutate(reference[start - 1:start - 1 + READ_LENGTH], mismatches.get(number, 0))
        flag = 0 if number % 2 else 16
        fields = [
            f"read{number:02d}", str(flag), CONTIG, str(start), str(quality_of.get(number, 60)),
            f"{READ_LENGTH}M", "*", "0", "0", sequence, quality,
            f"NM:i:{mismatches.get(number, 0)}", f"RG:Z:{READ_GROUP}",
        ]
        lines.append("\t".join(fields))
    for number, start in ((3, 801), (8, 401)):
        sequence = reference[start - 1:start - 1 + 50]
        fields = [
            f"read{number:02d}", "2048", CONTIG, str(start), "60", "50M50H", "*", "0", "0",
            sequence, "I" * 50, "NM:i:0", f"RG:Z:{READ_GROUP}",
        ]
        lines.append("\t".join(fields))
    unmapped = "".join(rng.choice("ACGT") for _ in range(READ_LENGTH))
    lines.append("\t".join(["read11", "4", "*", "0", "0", "*", "*", "0", "0", unmapped, quality, f"RG:Z:{READ_GROUP}"]))
    return "\n".join(lines) + "\n"


def main(fixture, scratch):
    rng = random.Random(20261026)
    reference = "".join(rng.choice("ACGT") for _ in range(CONTIG_LENGTH))
    scratch.mkdir(parents=True, exist_ok=True)
    sam = scratch / "fixture.sam"
    unsorted = scratch / "fixture.unsorted.bam"
    sam.write_text(sam_text(reference, rng))
    result_bam = fixture / RESULT_BAM
    for stale in (result_bam, Path(str(result_bam) + ".bai")):
        stale.unlink(missing_ok=True)
    # --no-PG keeps the account's scratch paths out of the BAM header (see BAMHeaderPathSanitizer).
    samtools("view", "--no-PG", "-b", "-o", str(unsorted), str(sam))
    samtools("sort", "--no-PG", "-o", str(result_bam), str(unsorted))
    samtools("index", str(result_bam))
    sam.unlink()
    unsorted.unlink()

    def count(*flags):
        return int(samtools("view", "-c", *flags, str(result_bam)).strip())

    assert count() == 13, "13 records"
    assert count("-F", "2308") == 10, "10 primary mapped reads"
    assert count("-f", "2048") == 2, "2 supplementary records"
    assert count("-f", "4") == 1, "1 unmapped read"
    assert count("-F", "2304") == 11, "11 primary records"

    idxstats = samtools("idxstats", str(result_bam))
    assert idxstats.splitlines()[0].split("\t") == [CONTIG, str(CONTIG_LENGTH), "12", "0"], idxstats

    flagstat = []
    for line in samtools("flagstat", str(result_bam)).splitlines():
        match = re.match(r"^(\d+) \+ (\d+) (.+)$", line.strip())
        if match:
            flagstat.append((normalize_flagstat_category(match.group(3)), int(match.group(1)), int(match.group(2))))
    flags = {category: passed for category, passed, _ in flagstat}
    expected = {"total": 13, "primary": 11, "secondary": 0, "supplementary": 2, "mapped": 12, "primary mapped": 10}
    for category, value in expected.items():
        assert flags[category] == value, (category, flags)

    coverage = samtools("coverage", "--ff", PRIMARY_EXCLUSION_FLAGS, str(result_bam)).splitlines()[1].split("\t")
    assert coverage[0] == CONTIG and int(coverage[3]) == 10, coverage
    mean_depth = float(coverage[6])
    coverage_breadth = float(coverage[5]) / 100
    median_mapq = float(statistics.median([60] * 8 + [30] * 2))
    mean_identity = 1 - (2 + 1) / (10 * READ_LENGTH)

    record = {
        "schemaVersion": 2,
        "mapper": "minimap2",
        "modeID": "short-read-default",
        "viewerBundlePath": VIEWER_BUNDLE,
        "bamPath": RESULT_BAM,
        "baiPath": RESULT_BAM + ".bai",
        "totalReads": 11,
        "mappedReads": 10,
        "unmappedReads": 1,
        "wallClockSeconds": 0.5,
        "referenceCount": 1,
        "unalignedReferenceCount": 0,
        "contigs": [{
            "readGroupIDs": [],
            "contigName": CONTIG,
            "contigLength": CONTIG_LENGTH,
            "mappedReads": 10,
            "mappedReadPercent": 10 / 11 * 100,
            "meanDepth": mean_depth,
            "coverageBreadth": coverage_breadth,
            "medianMAPQ": median_mapq,
            "meanIdentity": mean_identity,
        }],
    }
    (fixture / "mapping-result.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")

    alignments = fixture / VIEWER_BUNDLE / "alignments"
    shutil.rmtree(fixture / VIEWER_BUNDLE, ignore_errors=True)
    alignments.mkdir(parents=True)
    track_bam = alignments / f"{TRACK_ID}.sorted.bam"
    shutil.copyfile(result_bam, track_bam)
    shutil.copyfile(str(result_bam) + ".bai", str(track_bam) + ".bai")

    header = samtools("view", "-H", str(result_bam))
    database = sqlite3.connect(str(alignments / f"{TRACK_ID}.stats.db"))
    database.executescript(SCHEMA)
    info = {
        "source_path_in_bundle": f"alignments/{TRACK_ID}.sorted.bam",
        "original_source_path": ORIGINAL_SOURCE_PATH,
        "original_source_format": "bam",
        "format": "bam",
        "import_date": "2026-10-26T00:00:00Z",
        "file_name": f"{TRACK_ID}.sorted.bam",
        "sam_version": "1.6",
        "sort_order": "coordinate",
        "reference_sequence_count": "1",
        "genome_size": str(CONTIG_LENGTH),
    }
    database.executemany("INSERT INTO file_info (key, value) VALUES (?, ?)", sorted(info.items()))
    database.execute(
        "INSERT INTO read_groups (id, sample, platform) VALUES (?, ?, ?)", (READ_GROUP, SAMPLE, "ILLUMINA")
    )
    database.execute("INSERT INTO chromosome_stats VALUES (?, ?, ?, ?)", (CONTIG, CONTIG_LENGTH, 12, 0))
    database.executemany(
        "INSERT INTO flag_stats (category, qc_pass, qc_fail) VALUES (?, ?, ?)", flagstat
    )
    for line in header.splitlines():
        if line.startswith("@PG"):
            tags = dict(part.split(":", 1) for part in line.split("\t")[1:])
            database.execute(
                "INSERT INTO program_records VALUES (?, ?, ?, ?, ?)",
                (tags.get("ID"), tags.get("PN"), tags.get("VN"), tags.get("CL"), tags.get("PP")),
            )
    database.commit()
    database.close()
    print(json.dumps({"flagstat": flags, "coverage": coverage, "record": record["contigs"][0]}, indent=1))


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
