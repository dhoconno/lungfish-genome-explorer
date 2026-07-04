// ONTBarcodeDemuxGenotypingPipeline+Scripts.swift - Embedded Python script payloads for ONT demux genotyping
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ONTBarcodeDemuxGenotypingPipeline {
    public static func writeFilterScript(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try filterScript.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func writeReportScript(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try reportScript.write(to: url, atomically: true, encoding: .utf8)
    }

}

private let filterScript = #"""
#!/usr/bin/env python3
import argparse
import csv
import gzip
import hashlib
import json
import os
import platform
import re
import sys
import time
import warnings
from collections import Counter, defaultdict
from datetime import datetime, timezone

import pysam


def parse_args():
    parser = argparse.ArgumentParser(description="Filter exact+indel/no-mismatch full-reference alignments and demultiplex retained BAM records by Fluidigm barcodes.")
    parser.add_argument("--input-bam", required=True)
    parser.add_argument("--reference-fasta", required=True)
    parser.add_argument("--barcodes")
    parser.add_argument("--demux-manifest", required=True)
    parser.add_argument("--sample-manifest")
    parser.add_argument("--assignment-mode", choices=["barcode", "query-prefix"], default="barcode")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--prefix", default="barcode08")
    parser.add_argument("--require-both-end-softclips", action="store_true")
    parser.add_argument("--max-mismatches", type=int, default=0)
    parser.add_argument("--min-support", type=int, default=1)
    parser.add_argument("--haplotype-min-sample-percent", type=float, default=0.0)
    parser.add_argument("--haplotype-min-locus-percent", type=float, default=0.0)
    parser.add_argument("--haplotype-min-locus-percent-override", action="append", default=[])
    parser.add_argument("--provenance-command", default=None)
    return parser.parse_args()


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def sha256(path, chunk_size=1024 * 1024):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path, role):
    try:
        stat = os.stat(path)
    except OSError:
        return {"path": path, "role": role, "exists": False}
    return {"path": path, "role": role, "exists": True, "sizeBytes": stat.st_size, "sha256": sha256(path)}


def open_text(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt")
    return open(path, "rt")


def load_reference_lengths(path):
    lengths = {}
    name = None
    length = 0
    with open_text(path) as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            if line.startswith(">"):
                if name is not None:
                    lengths[name] = length
                name = line[1:].split()[0]
                length = 0
            else:
                length += len(line)
    if name is not None:
        lengths[name] = length
    return lengths


def parse_reference_metadata(name):
    metadata = {}
    for part in name.split("|")[1:]:
        if "=" in part:
            key, value = part.split("=", 1)
            metadata[key] = value
    return metadata


def load_reference_records(path):
    records = {}
    name = None
    chunks = []
    with open_text(path) as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            if line.startswith(">"):
                if name is not None:
                    sequence = "".join(chunks).upper()
                    records[name] = {
                        "sequence": sequence,
                        "length": len(sequence),
                        "metadata": parse_reference_metadata(name),
                    }
                name = line[1:].split()[0]
                chunks = []
            else:
                chunks.append(line)
    if name is not None:
        sequence = "".join(chunks).upper()
        records[name] = {
            "sequence": sequence,
            "length": len(sequence),
            "metadata": parse_reference_metadata(name),
        }
    return records


def load_barcodes(path):
    entries = []
    with open(path, newline="") as handle:
        sample = handle.read(2048)
        handle.seek(0)
        delimiter = "\t" if "\t" in sample and sample.count("\t") >= sample.count(",") else ","
        reader = csv.reader(handle, delimiter=delimiter)
        for row in reader:
            if not row or len(row) < 2:
                continue
            first = row[0].strip().lstrip("\ufeff")
            second = row[1].strip()
            if not first or not second:
                continue
            if first.lower() in {"sample", "sample_id", "id", "barcodeid"}:
                continue
            entries.append({"sample": first, "barcode": second.upper().replace("U", "T")})
    if not entries:
        raise ValueError(f"No barcodes found in {path}")
    return entries


def load_demux_manifest(path):
    with open(path) as handle:
        payload = json.load(handle)
    sample_totals = {}
    for item in payload.get("barcodes", []):
        sample = item.get("barcodeID")
        if sample:
            sample_totals[sample] = item.get("readCount")
    for item in payload.get("samples", []):
        sample = item.get("sample") or item.get("sampleID")
        if sample:
            sample_totals[sample] = item.get("totalPairs") or item.get("readCount") or item.get("mergedPairs")
    return {"inputReadCount": payload.get("inputReadCount"), "sampleTotals": sample_totals}


def reverse_complement(sequence):
    table = str.maketrans("ACGTNacgtn", "TGCANtgcan")
    return sequence.translate(table)[::-1].upper()


def fraction_from_percent(value):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 0.0
    if number <= 0:
        return 0.0
    return min(number, 100.0) / 100.0


def parse_locus_fraction_overrides(items):
    values = {}
    for item in items or []:
        if "=" not in item:
            raise ValueError("--haplotype-min-locus-percent-override must be LOCUS=PERCENT")
        locus, percent = item.split("=", 1)
        locus = locus.strip()
        if not locus:
            raise ValueError("--haplotype-min-locus-percent-override locus must not be empty")
        values[locus] = fraction_from_percent(percent)
    return {key: value for key, value in values.items() if value > 0}


def raw_locus_group_for_genotype(genotype):
    text = str(genotype or "").strip()
    if text.startswith("14_"):
        if "DQB" in text:
            return "MHC-DQB"
        return "MHC-DQA"
    if text.startswith("15_"):
        if "DPB" in text:
            return "MHC-DPB"
        return "MHC-DPA"
    if text.startswith("13_"):
        return "MHC-DRB"
    if text.startswith("12_") or text.startswith("B") or text.startswith("I_"):
        return "MHC-B"
    if text.startswith(("01_", "02_", "04_", "05_", "06_", "07_", "10_", "11_", "AG_", "A1_", "A2_", "A4_", "A5_", "E_")):
        return "MHC-A"
    return "MHC-UNKNOWN"


def canonical_locus_for_threshold(raw_locus):
    if raw_locus in {"MHC-DQA", "MHC-DQB"}:
        return "MHC-DQ"
    if raw_locus in {"MHC-DPA", "MHC-DPB"}:
        return "MHC-DP"
    return raw_locus


def reference_source_locus(reference_name, reference_records):
    record = reference_records.get(reference_name, {})
    metadata = record.get("metadata", {})
    source_loci = metadata.get("source_loci")
    if source_loci:
        return source_loci
    return raw_locus_group_for_genotype(reference_name)


def barcode_regex(entries):
    pattern_to_sample = {}
    ordered_patterns = []
    for entry in entries:
        for pattern in (entry["barcode"], reverse_complement(entry["barcode"])):
            if pattern not in pattern_to_sample:
                pattern_to_sample[pattern] = entry
                ordered_patterns.append(pattern)
    return re.compile("|".join(re.escape(pattern) for pattern in ordered_patterns)), pattern_to_sample


def assign_barcode(sequence, regex, pattern_to_sample):
    if not sequence:
        return None
    match = regex.search(sequence.upper().replace("U", "T"))
    if match is None:
        return None
    entry = pattern_to_sample[match.group(0)]
    return entry["sample"], entry["barcode"], match.start()


def assign_query_prefix(query_name, sample_totals):
    if not query_name or "|" not in query_name:
        return None
    sample = query_name.split("|", 1)[0]
    if sample not in sample_totals:
        return None
    return sample, "", 0


def query_weight(query_name):
    if not query_name:
        return 1
    for token in re.split(r"[;|\s]+", query_name):
        if token.startswith("size="):
            try:
                value = int(token.split("=", 1)[1])
            except ValueError:
                continue
            if value > 0:
                return value
    return 1


def sequence_for_barcode_assignment(read):
    sequence = read.query_sequence
    if not sequence:
        return None
    try:
        is_reverse = read.is_reverse
    except AttributeError:
        is_reverse = False
    if is_reverse:
        return reverse_complement(sequence)
    return sequence


def weighted_query_count(query_names, query_weights):
    return sum(query_weights.get(name, query_weight(name)) for name in query_names)


def has_both_terminal_softclips(read):
    cigar = [item for item in (read.cigartuples or []) if item[0] != 5]
    return len(cigar) >= 3 and cigar[0][0] == 4 and cigar[-1][0] == 4


def reference_span_is_full(read, reference_lengths):
    ref_length = reference_lengths.get(read.reference_name)
    return ref_length is not None and read.reference_start == 0 and read.reference_end == ref_length


def md_mismatch_count(md):
    mismatches = 0
    i = 0
    while i < len(md):
        char = md[i]
        if char.isdigit():
            i += 1
            while i < len(md) and md[i].isdigit():
                i += 1
            continue
        if char == "^":
            i += 1
            while i < len(md) and md[i].isalpha():
                i += 1
            continue
        if char.isalpha():
            mismatches += 1
        i += 1
    return mismatches


def alignment_mismatch_count(read):
    try:
        return md_mismatch_count(read.get_tag("MD"))
    except KeyError:
        return None


def passes_strict_filter(read, reference_lengths, args, counters):
    if read.is_unmapped:
        counters["unmapped"] += 1
        return False
    if not reference_span_is_full(read, reference_lengths):
        counters["not_full_reference_span"] += 1
        return False
    if args.require_both_end_softclips and not has_both_terminal_softclips(read):
        counters["missing_terminal_softclips"] += 1
        return False
    mismatches = alignment_mismatch_count(read)
    if mismatches is None:
        counters["missing_md_tag"] += 1
        return False
    if mismatches > args.max_mismatches:
        counters["too_many_mismatches"] += 1
        return False
    counters["passed"] += 1
    return True


def passes_filter(read, reference_lengths, reference_records, args, counters):
    return passes_strict_filter(read, reference_lengths, args, counters)


def write_csv(path, rows, fieldnames):
    with open(path, "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def main():
    args = parse_args()
    start_time = time.time()
    started_at = utc_now()
    os.makedirs(args.output_dir, exist_ok=True)
    min_sample_fraction = fraction_from_percent(args.haplotype_min_sample_percent)
    min_locus_fraction = fraction_from_percent(args.haplotype_min_locus_percent)
    locus_fraction_overrides = parse_locus_fraction_overrides(args.haplotype_min_locus_percent_override)
    reference_records = load_reference_records(args.reference_fasta)
    reference_lengths = {name: record["length"] for name, record in reference_records.items()}
    manifest = load_demux_manifest(args.sample_manifest or args.demux_manifest)
    if args.assignment_mode == "barcode":
        if not args.barcodes:
            raise ValueError("--barcodes is required when --assignment-mode=barcode")
        barcode_entries = load_barcodes(args.barcodes)
        regex, pattern_to_sample = barcode_regex(barcode_entries)
    else:
        regex, pattern_to_sample = None, None
    total_input_reads = manifest["inputReadCount"]
    output_bam = os.path.join(args.output_dir, f"{args.prefix}.retained.demuxed.bam")
    output_bai = output_bam + ".bai"
    summary_csv = os.path.join(args.output_dir, f"{args.prefix}.retained_demux_genotypes.csv")
    sample_csv = os.path.join(args.output_dir, f"{args.prefix}.retained_demux_samples.csv")
    stats_json = os.path.join(args.output_dir, f"{args.prefix}.retained_demux_stats.json")
    provenance_json = os.path.join(args.output_dir, f"{args.prefix}.retained_demux_provenance.json")

    total_alignments = 0
    pass_counters = Counter()
    retained_query_names = set()
    with pysam.AlignmentFile(args.input_bam, "rb") as source:
        for read in source.fetch(until_eof=True):
            total_alignments += 1
            if passes_filter(read, reference_lengths, reference_records, args, pass_counters):
                retained_query_names.add(read.query_name)

    barcode_cache = {}
    barcode_cache_counts = Counter()
    sequence_records_seen = 0
    retained_sequence_records_seen = 0
    with pysam.AlignmentFile(args.input_bam, "rb") as source:
        for read in source.fetch(until_eof=True):
            sequence = sequence_for_barcode_assignment(read)
            if not sequence:
                continue
            sequence_records_seen += 1
            if read.query_name not in retained_query_names:
                continue
            retained_sequence_records_seen += 1
            if read.query_name in barcode_cache:
                continue
            if args.assignment_mode == "query-prefix":
                assignment = assign_query_prefix(read.query_name, manifest["sampleTotals"])
            else:
                assignment = assign_barcode(sequence, regex, pattern_to_sample)
            if assignment is not None:
                sample, barcode, start = assignment
                barcode_cache[read.query_name] = (sample, barcode, start)
                barcode_cache_counts[sample] += query_weight(read.query_name)

    genotype_alignment_counts = Counter()
    genotype_unique_reads = defaultdict(set)
    sample_locus_unique_reads = defaultdict(set)
    sample_alignment_counts = Counter()
    sample_unique_reads = defaultdict(set)
    retained_unique_reads = set()
    unassigned_unique_reads = set()
    query_weights = {}
    write_filter_counters = Counter()
    with pysam.AlignmentFile(args.input_bam, "rb") as source:
        header = source.header.to_dict()
        comments = header.get("CO", [])
        comments.append(f"Filtered by lungfish fastq genotype: full-reference MD-tag mismatches <= max-mismatches; indels allowed; sample assignment mode={args.assignment_mode}; sample in LF tag.")
        header["CO"] = comments
        with pysam.AlignmentFile(output_bam, "wb", header=header) as dest:
            for read in source.fetch(until_eof=True):
                if not passes_filter(read, reference_lengths, reference_records, args, write_filter_counters):
                    continue
                assignment = barcode_cache.get(read.query_name)
                if assignment is None:
                    sample = "unassigned"
                    barcode = ""
                    unassigned_unique_reads.add(read.query_name)
                else:
                    sample, barcode, _ = assignment
                    read.set_tag("LF", sample, value_type="Z")
                    read.set_tag("BC", barcode, value_type="Z")
                    sample_unique_reads[sample].add(read.query_name)
                weight = query_weight(read.query_name)
                query_weights[read.query_name] = weight
                retained_unique_reads.add(read.query_name)
                key = (sample, read.reference_name)
                genotype_alignment_counts[key] += weight
                genotype_unique_reads[key].add(read.query_name)
                locus_group = raw_locus_group_for_genotype(read.reference_name)
                sample_locus_unique_reads[(sample, locus_group)].add(read.query_name)
                sample_alignment_counts[sample] += weight
                dest.write(read)
    pysam.index(output_bam)

    retained_unique_count = weighted_query_count(retained_unique_reads, query_weights)
    assigned_unique_count = sum(
        weighted_query_count(values, query_weights)
        for sample, values in sample_unique_reads.items()
        if sample != "unassigned"
    )
    unassigned_unique_count = weighted_query_count(unassigned_unique_reads, query_weights)
    retained_percent = (retained_unique_count / total_input_reads * 100.0) if total_input_reads else None

    genotype_rows = []
    for (sample, genotype), count in sorted(genotype_alignment_counts.items(), key=lambda item: (item[0][0], -item[1], item[0][1])):
        unique_read_count = weighted_query_count(genotype_unique_reads[(sample, genotype)], query_weights)
        sample_total = manifest["sampleTotals"].get(sample)
        sample_unique_count = (
            weighted_query_count(sample_unique_reads.get(sample, set()), query_weights)
            if sample != "unassigned"
            else unassigned_unique_count
        )
        genotype_rows.append({
            "sample": sample,
            "genotype": genotype,
            "passed_alignments": count,
            "passed_unique_reads": unique_read_count,
            "sample_total_reads": sample_total if sample_total is not None else "",
            "sample_unique_retained_reads": sample_unique_count,
            "sample_unique_retained_percent": f"{(sample_unique_count / sample_total * 100.0):.6f}" if sample_total else "",
            "overall_input_reads": total_input_reads,
            "overall_unique_retained_reads": retained_unique_count,
            "overall_unique_retained_percent": f"{retained_percent:.6f}" if retained_percent is not None else "",
        })
    write_csv(summary_csv, genotype_rows, ["sample", "genotype", "passed_alignments", "passed_unique_reads", "sample_total_reads", "sample_unique_retained_reads", "sample_unique_retained_percent", "overall_input_reads", "overall_unique_retained_reads", "overall_unique_retained_percent"])

    sample_rows = []
    all_samples = sorted(set(sample_alignment_counts) | set(manifest["sampleTotals"]))
    for sample in all_samples:
        sample_total = manifest["sampleTotals"].get(sample)
        unique_count = (
            weighted_query_count(sample_unique_reads.get(sample, set()), query_weights)
            if sample != "unassigned"
            else unassigned_unique_count
        )
        sample_rows.append({
            "sample": sample,
            "passed_alignments": sample_alignment_counts.get(sample, 0),
            "passed_unique_reads": unique_count,
            "sample_total_reads": sample_total if sample_total is not None else "",
            "sample_unique_retained_percent": f"{(unique_count / sample_total * 100.0):.6f}" if sample_total else "",
            "overall_input_reads": total_input_reads,
            "overall_unique_retained_percent": f"{retained_percent:.6f}" if retained_percent is not None else "",
        })
    write_csv(sample_csv, sample_rows, ["sample", "passed_alignments", "passed_unique_reads", "sample_total_reads", "sample_unique_retained_percent", "overall_input_reads", "overall_unique_retained_percent"])

    completed_at = utc_now()
    stats = {
        "tool": "lungfish fastq ont-barcode-genotype retained-read filter",
        "version": "1",
        "startedAt": started_at,
        "completedAt": completed_at,
        "wallClockSeconds": time.time() - start_time,
        "inputBAM": args.input_bam,
        "referenceFasta": args.reference_fasta,
        "barcodes": args.barcodes,
        "demuxManifest": args.demux_manifest,
        "sampleManifest": args.sample_manifest,
        "assignmentMode": args.assignment_mode,
        "outputBAM": output_bam,
        "outputBAI": output_bai,
        "summaryCSV": summary_csv,
        "sampleCSV": sample_csv,
        "totalInputReads": total_input_reads,
        "totalAlignments": total_alignments,
        "sequenceRecordsSeen": sequence_records_seen,
        "retainedSequenceRecordsSeen": retained_sequence_records_seen,
        "retainedQueryNamesBeforeDemux": len(retained_query_names),
        "barcodeCacheReadCount": len(barcode_cache),
        "barcodeCacheCounts": dict(barcode_cache_counts),
        "passCounters": dict(pass_counters),
        "writeFilterCounters": dict(write_filter_counters),
        "passedAlignments": pass_counters["passed"],
        "retainedUniqueReads": retained_unique_count,
        "retainedUniquePercentOfTotalReads": retained_percent,
        "assignedUniqueRetainedReads": assigned_unique_count,
        "unassignedUniqueRetainedReads": unassigned_unique_count,
        "requireBothEndSoftclips": args.require_both_end_softclips,
        "requireFullReferenceSpan": True,
        "diagnosticPositionFilter": False,
        "diagnosticPositionStrictLoci": [],
        "allowIndels": True,
        "maxMismatches": args.max_mismatches,
        "demuxRetainedReadsOnly": args.assignment_mode == "barcode",
        "minSupport": args.min_support,
        "haplotypeMinSamplePercent": args.haplotype_min_sample_percent,
        "haplotypeMinLocusPercent": args.haplotype_min_locus_percent,
        "haplotypeMinLocusPercentOverrides": args.haplotype_min_locus_percent_override,
    }
    with open(stats_json, "w") as handle:
        json.dump(stats, handle, indent=2, sort_keys=True)
        handle.write("\n")

    provenance = {
        "toolName": "lungfish fastq ont-barcode-genotype retained-read filter",
        "toolVersion": "1",
        "argv": sys.argv,
        "reproducibleCommand": args.provenance_command or " ".join(sys.argv),
        "options": vars(args),
        "resolvedDefaults": {
            "maxMismatches": args.max_mismatches,
            "diagnosticPositionFilter": False,
            "diagnosticPositionStrictLoci": [],
            "requireFullReferenceSpan": True,
            "requireBothEndSoftclips": args.require_both_end_softclips,
            "minSupport": args.min_support,
            "haplotypeMinSamplePercent": 0.0,
            "haplotypeMinLocusPercent": 0.0,
            "haplotypeMinLocusPercentOverrides": [],
            "demuxRetainedReadsOnly": args.assignment_mode == "barcode"
        },
        "runtimeIdentity": {"python": sys.version, "platform": platform.platform(), "pysam": pysam.__version__, "executable": sys.executable},
        "inputs": [record for record in [
            file_record(args.input_bam, "input"),
            file_record(args.reference_fasta, "input"),
            file_record(args.barcodes, "input") if args.barcodes else None,
            file_record(args.demux_manifest, "input"),
            file_record(args.sample_manifest, "input") if args.sample_manifest else None,
        ] if record is not None],
        "outputs": [file_record(output_bam, "output"), file_record(output_bai, "output"), file_record(summary_csv, "output"), file_record(sample_csv, "output"), file_record(stats_json, "output")],
        "exitStatus": 0,
        "wallClockSeconds": stats["wallClockSeconds"],
        "stderr": "",
        "startedAt": started_at,
        "completedAt": completed_at,
    }
    with open(provenance_json, "w") as handle:
        json.dump(provenance, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(json.dumps(stats, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
"""#

private let reportScript = #"""
#!/usr/bin/env python3
import argparse
import csv
import gzip
import hashlib
import json
import os
import platform
import re
import sys
import time
import warnings
from collections import defaultdict
from copy import copy, deepcopy
from datetime import datetime, timezone

import openpyxl
from openpyxl import Workbook, load_workbook
from openpyxl.comments import Comment
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter


GENE_PREFIXES = (
    "DQB1",
    "DQA1",
    "DPB1",
    "DPA1",
    "DRB1",
    "DRB",
    "B11L",
    "B17",
    "B20",
    "A1",
    "A2",
    "A3",
    "A4",
    "AG",
    "B",
    "E",
    "F",
    "G",
    "I",
)


def parse_args():
    parser = argparse.ArgumentParser(description="Write ONT retained-demux genotype CSVs to an Excel workbook.")
    parser.add_argument("--genotypes-csv", required=True)
    parser.add_argument("--samples-csv", required=True)
    parser.add_argument("--stats-json", required=True)
    parser.add_argument("--reference-fasta", required=True)
    parser.add_argument("--barcode-definitions", required=True)
    parser.add_argument("--output-xlsx", required=True)
    parser.add_argument("--provenance-json", required=True)
    parser.add_argument("--analysis-name")
    parser.add_argument("--run-name", default="ont-barcode-genotyping")
    parser.add_argument("--comparison-workbook")
    parser.add_argument("--comparison-name", default="Illumina-31262")
    parser.add_argument("--haplotype-analysis-json")
    parser.add_argument("--client-current-workbook", action="store_true")
    parser.add_argument("--haplotype-definition-json")
    parser.add_argument("--primary-workbook")
    parser.add_argument("--provenance-command")
    args = parser.parse_args()
    if not args.analysis_name:
        args.analysis_name = args.run_name
    return args


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def sha256(path, chunk_size=1024 * 1024):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path, role):
    try:
        stat = os.stat(path)
    except OSError:
        return {"path": path, "role": role, "exists": False}
    return {"path": path, "role": role, "exists": True, "sizeBytes": stat.st_size, "sha256": sha256(path)}


def clean_csv_text(value):
    if value is None:
        return ""
    return str(value).replace("\ufeff", "").strip()


def read_csv(path):
    with open(path, newline="") as handle:
        reader = csv.DictReader(handle)
        fieldnames = [clean_csv_text(field) for field in (reader.fieldnames or [])]
        rows = [
            {
                clean_csv_text(key): clean_csv_text(value)
                for key, value in row.items()
                if key is not None
            }
            for row in reader
        ]
        return fieldnames, rows


def as_number(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return value
    text = str(value).strip()
    if not text:
        return None
    try:
        number = float(text)
    except ValueError:
        return None
    if number.is_integer():
        return int(number)
    return number


def display_value(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return value
    text = str(value).strip()
    if text == "":
        return None
    number = as_number(text)
    return number if number is not None else text


def load_genotype_counts(rows):
    counts = defaultdict(dict)
    for row in rows:
        sample = row.get("sample", "").strip()
        genotype = row.get("genotype", "").strip()
        if not sample or not genotype:
            continue
        count = as_number(row.get("passed_alignments"))
        if count is None:
            count = 0
        counts[sample][genotype] = counts[sample].get(genotype, 0) + int(count)
    return counts


def load_sample_stats(rows):
    stats = {}
    for row in rows:
        sample = row.get("sample", "").strip()
        if sample:
            stats[sample] = row
    return stats


def has_positive_retained_reads(row):
    for key in ("passed_alignments", "passed_unique_reads", "sample_unique_retained_reads"):
        value = as_number(row.get(key))
        if value is not None and value > 0:
            return True
    return False


def report_sample_names(sample_rows, genotype_counts):
    names = []
    seen = set()

    for row in sample_rows:
        sample = row.get("sample", "").strip()
        if not is_assigned_sample_name(sample) or sample in seen:
            continue
        genotype_total = sum(int(count) for count in genotype_counts.get(sample, {}).values())
        if has_positive_retained_reads(row) or genotype_total > 0:
            names.append(sample)
            seen.add(sample)

    for sample, counts in genotype_counts.items():
        if not is_assigned_sample_name(sample) or sample in seen:
            continue
        if sum(int(count) for count in counts.values()) > 0:
            names.append(sample)
            seen.add(sample)

    return names


def rows_for_samples(rows, samples):
    sample_set = set(samples)
    return [row for row in rows if row.get("sample", "").strip() in sample_set]


def is_assigned_sample_name(sample):
    text = str(sample or "").strip()
    return bool(text) and text.lower() != "unassigned"


def assigned_sample_rows(rows):
    return [row for row in rows if is_assigned_sample_name(row.get("sample"))]


def open_text(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt")
    return open(path, "rt")


def reference_names(path):
    names = []
    with open_text(path) as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if line.startswith(">"):
                names.append(line[1:].split()[0])
    return names


def clean_expected_part(part):
    part = re.sub(r"^\d+_", "", part)
    for prefix in GENE_PREFIXES:
        marker = f"_{prefix}_"
        if marker in part:
            part = part.split(marker, 1)[1]
            part = f"{prefix}_{part}"
            break
        if part.startswith(f"{prefix}_"):
            break
    else:
        part = re.sub(r"^M[0-9A-Za-z]+_", "", part)
    part = re.sub(r"_\d+bp$", "", part)
    return part


def tokens_for_expected(label):
    if label is None:
        return []
    tokens = []
    for raw_part in str(label).split(":"):
        token = clean_expected_part(raw_part.strip())
        if token:
            tokens.append(token)

    expanded = []
    for token in tokens:
        expanded.append(token)
        if token == "G_02_0508_g48c":
            expanded.append("G_02_05/08_g48c")
        if token == "AG_g3ex":
            expanded.append("AG_03g")
        if token == "AG_g6ex":
            expanded.append("AG_06g")
        if token in {"AG_06g1", "AG_06g2_t135a"}:
            expanded.append("AG_06g")
        if token == "B11L_01g2ex":
            expanded.append("B11L_01")
        if token == "DPA1_02_02":
            expanded.append("DPA1_02g")
        if token == "I_01g":
            expanded.extend(["I_01g1", "I_01g2", "I_01g3", "I_01g4"])
        if token == "B_098g":
            expanded.extend(["B_098g1", "B_098g2", "B_098g3"])

    deduped = []
    for token in expanded:
        if token and token not in deduped:
            deduped.append(token)
    return deduped


def matched_count(tokens, sample_counts):
    if not tokens:
        return 0, []
    total = 0
    names = []
    for genotype, count in sample_counts.items():
        if any(token in genotype for token in tokens):
            total += int(count)
            names.append(genotype)
    return total, names


def safe_sheet_title(workbook, desired, fallback):
    invalid = set("[]:*?/\\")
    title = "".join("_" if char in invalid else char for char in str(desired or fallback)).strip()
    title = title or fallback
    title = title[:31].rstrip()
    existing = {sheet.title for sheet in workbook.worksheets}
    if title not in existing:
        return title
    base = title
    index = 2
    while True:
        suffix = f" {index}"
        candidate = f"{base[:31 - len(suffix)]}{suffix}".rstrip()
        if candidate not in existing:
            return candidate
        index += 1


def remove_tables(ws):
    for name in list(ws.tables.keys()):
        del ws.tables[name]


def copy_conditional_formatting(source, destination):
    destination.conditional_formatting._cf_rules = deepcopy(source.conditional_formatting._cf_rules)


def sample_columns(ws):
    columns = []
    for col in range(4, ws.max_column + 1):
        value = ws.cell(2, col).value
        if value is None or str(value).strip() == "":
            continue
        columns.append((col, str(value).strip()))
    return columns


def formula_range(sample_cols, row):
    if not sample_cols:
        return None
    first = get_column_letter(sample_cols[0][0])
    last = get_column_letter(sample_cols[-1][0])
    return f"{first}{row}:{last}{row}"


def copy_cell_style(source, destination):
    if source.has_style:
        destination.font = copy(source.font)
        destination.fill = copy(source.fill)
        destination.border = copy(source.border)
        destination.alignment = copy(source.alignment)
        destination.number_format = source.number_format
        destination.protection = copy(source.protection)


def compact_analysis_sample_columns(ws, samples):
    start_col = 4
    target_count = len(samples)
    existing_count = max(0, ws.max_column - start_col + 1)

    if existing_count > target_count:
        ws.delete_cols(start_col + target_count, existing_count - target_count)
    elif existing_count < target_count:
        style_source_col = start_col + existing_count - 1 if existing_count > 0 else 3
        for col in range(start_col + existing_count, start_col + target_count):
            source_letter = get_column_letter(style_source_col)
            target_letter = get_column_letter(col)
            ws.column_dimensions[target_letter].width = ws.column_dimensions[source_letter].width
            for row in range(1, ws.max_row + 1):
                copy_cell_style(ws.cell(row, style_source_col), ws.cell(row, col))

    for offset, sample in enumerate(samples):
        col = start_col + offset
        ws.cell(1, col).value = sample
        ws.cell(2, col).value = sample

    return sample_columns(ws)


def copied_template_workbook(path, analysis_name, comparison_name):
    wb = load_workbook(path)
    while len(wb.worksheets) > 1:
        wb.remove(wb.worksheets[-1])
    analysis_ws = wb.worksheets[0]
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        comparison_ws = wb.copy_worksheet(analysis_ws)
    copy_conditional_formatting(analysis_ws, comparison_ws)
    analysis_ws.title = safe_sheet_title(wb, analysis_name, "ONT08")
    comparison_ws.title = safe_sheet_title(wb, comparison_name, "Illumina-31262")
    remove_tables(analysis_ws)
    remove_tables(comparison_ws)
    return wb, analysis_ws, comparison_ws


def row_looks_like_allele_call(ws, row):
    label = ws.cell(row, 1).value
    if row < 22 or not isinstance(label, str):
        return False
    b_value = ws.cell(row, 2).value
    c_value = ws.cell(row, 3).value
    if isinstance(b_value, str) and b_value.startswith("="):
        return True
    if isinstance(c_value, str) and c_value.startswith("="):
        return True
    if as_number(b_value) is not None or as_number(c_value) is not None:
        return True
    return False


def fill_formula_totals(ws, rows, sample_cols):
    for row in rows:
        cell_range = formula_range(sample_cols, row)
        if not cell_range:
            continue
        ws.cell(row, 2).value = f"=SUM({cell_range})"
        ws.cell(row, 3).value = f"=COUNT({cell_range})"


def sample_numbers(ws, row, sample_cols):
    values = []
    for col, _sample in sample_cols:
        number = as_number(ws.cell(row, col).value)
        if number is not None:
            values.append(number)
    return values


def fill_read_count_summary_values(ws, row, sample_cols):
    values = sample_numbers(ws, row, sample_cols)
    total = sum(values) if values else 0
    average = total / len(values) if values else 0
    ws.cell(row, 2).value = total
    ws.cell(row, 3).value = average


def fill_subtotal_observed_values(ws, rows, sample_cols):
    for row in rows:
        values = sample_numbers(ws, row, sample_cols)
        ws.cell(row, 2).value = sum(values) if values else 0
        ws.cell(row, 3).value = sum(1 for value in values if value > 0)


def clear_cells(ws, row, start_col=1):
    for col in range(start_col, ws.max_column + 1):
        ws.cell(row, col).value = None


def clear_analysis_template_sample_values(ws):
    if ws.max_row >= 5:
        ws.cell(3, 1).value = "Filtered exact-match read count"
        clear_cells(ws, 4)
        clear_cells(ws, 5)

    for row in range(6, min(ws.max_row, 19) + 1):
        clear_cells(ws, row, start_col=2)

    if ws.max_row >= 20 and ws.cell(20, 1).value == "Comments":
        ws.cell(20, 2).value = "Subtotal"
        ws.cell(20, 3).value = "# Obs."
        clear_cells(ws, 20, start_col=4)


def row_has_sample_count(ws, row, sample_cols):
    for col, _sample in sample_cols:
        count = as_number(ws.cell(row, col).value) or 0
        if count > 0:
            return True
    return False


def prune_zero_allele_rows(ws, allele_rows, sample_cols):
    for row in sorted(allele_rows, reverse=True):
        if not row_has_sample_count(ws, row, sample_cols):
            ws.delete_rows(row)


def is_locus_header_row(ws, row):
    label = ws.cell(row, 1).value
    return row >= 21 and isinstance(label, str) and not row_looks_like_allele_call(ws, row)


def prune_empty_locus_headers(ws):
    header_rows = [row for row in range(21, ws.max_row + 1) if is_locus_header_row(ws, row)]
    for index in range(len(header_rows) - 1, -1, -1):
        row = header_rows[index]
        next_header = header_rows[index + 1] if index + 1 < len(header_rows) else ws.max_row + 1
        has_allele = any(row_looks_like_allele_call(ws, candidate) for candidate in range(row + 1, next_header))
        if not has_allele:
            ws.delete_rows(row)


def fill_analysis_sheet(ws, genotype_counts, sample_stats, samples):
    cols = compact_analysis_sample_columns(ws, samples)
    clear_analysis_template_sample_values(ws)

    allele_rows = [row for row in range(1, ws.max_row + 1) if row_looks_like_allele_call(ws, row)]

    for col, sample in cols:
        stats = sample_stats.get(sample, {})
        ws.cell(3, col).value = display_value(stats.get("passed_alignments"))

    matched_by_row_sample = {}
    for row in allele_rows:
        label = ws.cell(row, 1).value
        tokens = tokens_for_expected(label)
        for col, sample in cols:
            count, names = matched_count(tokens, genotype_counts.get(sample, {}))
            ws.cell(row, col).value = count if count > 0 else None
            matched_by_row_sample[(row, sample)] = (count, names, tokens)
    prune_zero_allele_rows(ws, allele_rows, cols)
    prune_empty_locus_headers(ws)
    final_allele_rows = [row for row in range(1, ws.max_row + 1) if row_looks_like_allele_call(ws, row)]
    fill_read_count_summary_values(ws, 3, cols)
    fill_subtotal_observed_values(ws, final_allele_rows, cols)
    return cols, allele_rows, matched_by_row_sample


def style_tabular_sheet(ws):
    header_fill = PatternFill("solid", fgColor="4472C4")
    header_font = Font(color="FFFFFF", bold=True)
    thin_gray = Side(style="thin", color="D9E2F3")
    for cell in ws[1]:
        cell.fill = header_fill
        cell.font = header_font
        cell.alignment = Alignment(horizontal="center")
        cell.border = Border(bottom=thin_gray)
    ws.freeze_panes = "A2"
    if ws.max_row and ws.max_column:
        ws.auto_filter.ref = ws.dimensions
    for col in range(1, ws.max_column + 1):
        letter = get_column_letter(col)
        max_len = 0
        for row in range(1, min(ws.max_row, 200) + 1):
            value = ws.cell(row, col).value
            if value is not None:
                max_len = max(max_len, len(str(value)))
        ws.column_dimensions[letter].width = min(max(max_len + 2, 10), 48)


def write_csv_sheet(wb, title, headers, rows):
    ws = wb.create_sheet(title=safe_sheet_title(wb, title, title[:31] or "Sheet"))
    ws.append(headers)
    for row in rows:
        ws.append([display_value(row.get(header)) for header in headers])
    style_tabular_sheet(ws)
    return ws


def write_stats_sheet(wb, stats):
    ws = wb.create_sheet(title=safe_sheet_title(wb, "Run Stats", "Run Stats"))
    ws.append(["metric", "value"])
    for key in sorted(stats):
        value = stats[key]
        if isinstance(value, (dict, list)):
            value = json.dumps(value, sort_keys=True)
        ws.append([key, display_value(value)])
    style_tabular_sheet(ws)
    return ws


def load_haplotype_analysis(path):
    if not path:
        return None
    with open(path) as handle:
        return json.load(handle)


def load_haplotype_definition(path):
    if not path:
        return {}
    with open(path) as handle:
        return json.load(handle)


def haplotype_calls_by_sample_locus(haplotype_analysis):
    by_sample = {}
    if not haplotype_analysis:
        return by_sample
    for sample in haplotype_analysis.get("samples", []):
        sample_id = str(sample.get("sample", "")).strip()
        if not sample_id:
            continue
        locus_map = {}
        for call in sample.get("calls", []):
            locus = str(call.get("locus", "")).strip()
            if locus:
                locus_map[locus] = call
        by_sample[sample_id] = locus_map
    return by_sample


def haplotype_row_targets(ws):
    targets = []
    for row in range(1, min(ws.max_row, 40) + 1):
        value = ws.cell(row, 1).value
        if not isinstance(value, str):
            continue
        match = re.match(r"^(MHC-[A-Za-z0-9]+) Haplotype ([12])$", value.strip())
        if match:
            targets.append((row, match.group(1), int(match.group(2))))
    return targets


def noncalled_haplotype_summary(locus_calls):
    messages = []
    for locus in sorted(locus_calls):
        call = locus_calls[locus]
        status = call.get("status")
        if status in (None, "called"):
            continue
        left = call.get("haplotype1") or ""
        right = call.get("haplotype2") or ""
        label = left if left == right or not right else f"{left}/{right}"
        messages.append(f"{locus}: {label}")
    return "; ".join(messages)


def fill_haplotype_rows(ws, sample_cols, haplotype_analysis):
    by_sample = haplotype_calls_by_sample_locus(haplotype_analysis)
    if not by_sample:
        return
    for row, locus, index in haplotype_row_targets(ws):
        key = f"haplotype{index}"
        for col, sample in sample_cols:
            call = by_sample.get(sample, {}).get(locus)
            ws.cell(row, col).value = call.get(key) if call else None
    comments_row = None
    for row in range(1, min(ws.max_row, 40) + 1):
        if ws.cell(row, 1).value == "Comments":
            comments_row = row
            break
    if comments_row:
        for col, sample in sample_cols:
            summary = noncalled_haplotype_summary(by_sample.get(sample, {}))
            ws.cell(comments_row, col).value = summary or None


def haplotype_loci_for_report(haplotype_analysis):
    fallback = [
        "MHC-A",
        "MHC-B",
        "MHC-DRB",
        "MHC-DQA",
        "MHC-DQB",
        "MHC-DPA",
        "MHC-DPB",
    ]
    if not haplotype_analysis:
        return fallback
    loci = []
    seen = set()
    for sample in haplotype_analysis.get("samples", []):
        for call in sample.get("calls", []):
            locus = str(call.get("locus", "")).strip()
            if locus and locus not in seen:
                loci.append(locus)
                seen.add(locus)
    return loci if loci else fallback


def write_haplotype_sheet(wb, haplotype_analysis):
    if not haplotype_analysis:
        return None
    ws = wb.create_sheet(title=safe_sheet_title(wb, "Haplotype Calls", "Haplotype Calls"))
    headers = [
        "sample",
        "locus",
        "haplotype_1",
        "haplotype_2",
        "status",
        "observed_genotype_count",
        "matched_haplotypes",
        "observed_genotypes",
        "notes",
    ]
    ws.append(headers)
    for sample in haplotype_analysis.get("samples", []):
        sample_id = sample.get("sample")
        for call in sample.get("calls", []):
            ws.append([
                sample_id,
                call.get("locus"),
                call.get("haplotype1"),
                call.get("haplotype2"),
                call.get("status"),
                call.get("observedGenotypeCount"),
                ";".join(item.get("name", "") for item in call.get("matchedHaplotypes", [])),
                ";".join(call.get("observedGenotypes", [])),
                call.get("notes"),
            ])
    style_tabular_sheet(ws)
    return ws


MCM_CLIENT_SHEET_NAMES = [
    "Interpretation Guide",
    "MHC Alleles Per MHC Haplotype",
    "Abbreviated Haplotypes",
    "Full Sequencing Results 1",
    "Custom Sort",
]

MCM_FAMILIES = ["M1", "M2", "M3", "M4", "M5", "M6", "M7"]
MCM_REPORT_LOCI = ["MHC-A", "MHC-B", "MHC-DRB", "MHC-DQ", "MHC-DP"]
MCM_FULL_SUMMARY_LOCI = ["MHC-A", "MHC-B", "MHC-DRB", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB"]
MCM_SUMMARY_DISPLAY_LOCI = [
    ("MHC-A", "MHC-A"),
    ("MHC-B", "MHC-B"),
    ("MHC-DRB", "MHC-DRB"),
    ("MHC-DQ", "MHC-DQA/B"),
    ("MHC-DP", "MHC-DPA/B"),
]
MCM_HAPLOTYPE_STYLES = {
    "M1": {"font": "000000"},
    "M2": {"font": "FF0000"},
    "M3": {"font": "0432FF"},
    "M4": {"font": "00B050"},
    "M5": {"font": "FFC000"},
    "M6": {"font": "595959"},
    "M7": {"font": "7030A0"},
}
MCM_ALLELE_SECTION_ORDER = [
    "Mafa-F alleles",
    "Mafa-G alleles",
    "Mafa-AG alleles",
    "Mafa-A major alleles",
    "Mafa-A minor alleles",
    "Mafa-70 alleles",
    "Mafa-E alleles",
    "Mafa-B alleles",
    "Mafa-DRB alleles",
    "Mafa-DQA/DQB alleles",
    "Mafa-DPA/DPB alleles",
]
MCM_ABBREVIATED_COLUMN_A_WIDTH = 17.33203125
MCM_CUSTOM_SORT_COLUMN_A_WIDTH = 16.83203125
MCM_FULL_COLUMN_A_WIDTH = 37.1640625


def mcm_family(value):
    if value is None:
        return None
    text = str(value).strip()
    if not text or text == "-" or text.startswith("ERR:"):
        return None
    match = re.search(r"\b(M[1-7])", text)
    return match.group(1) if match else None


def mcm_families(value):
    if value is None:
        return []
    seen = set()
    families = []
    for match in re.finditer(r"M[1-7]", str(value)):
        family = match.group(0)
        if family not in seen:
            families.append(family)
            seen.add(family)
    return families


def mcm_style_for_family(family):
    return MCM_HAPLOTYPE_STYLES.get(family, {})


def clear_cell_fill(cell):
    cell.fill = PatternFill(fill_type=None)


def apply_haplotype_cell_style(cell, value):
    family = mcm_family(value)
    clear_cell_fill(cell)
    if not family:
        if isinstance(value, str) and value.startswith("ERR:"):
            cell.font = Font(name="Calibri", size=11, color="9C0006", bold=True)
            cell.alignment = Alignment(horizontal="center", vertical="center")
        return
    style = mcm_style_for_family(family)
    if not style:
        return
    cell.font = Font(name="Calibri", size=11, color=style["font"], bold=True)
    cell.alignment = Alignment(horizontal="center", vertical="center")


def apply_basic_sheet_format(ws, freeze_panes=None, auto_filter=True):
    header_fill = PatternFill("solid", fgColor="D9EAF7")
    header_font = Font(name="Calibri", size=11, bold=True)
    body_font = Font(name="Calibri", size=11)
    thin_gray = Side(style="thin", color="D9D9D9")
    for row in ws.iter_rows():
        for cell in row:
            cell.border = Border(bottom=thin_gray)
            cell.font = body_font
            cell.alignment = Alignment(vertical="top", wrap_text=True)
    for cell in ws[1]:
        cell.fill = header_fill
        cell.font = header_font
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    if freeze_panes:
        ws.freeze_panes = freeze_panes
    if auto_filter and ws.max_row and ws.max_column:
        ws.auto_filter.ref = ws.dimensions
    else:
        ws.auto_filter.ref = None
    for col in range(1, ws.max_column + 1):
        letter = get_column_letter(col)
        max_len = 0
        for row in range(1, min(ws.max_row, 120) + 1):
            value = ws.cell(row, col).value
            if value is not None:
                parts = str(value).splitlines() or [str(value)]
                max_len = max(max_len, max(len(part) for part in parts))
        ws.column_dimensions[letter].width = min(max(max_len + 2, 10), 36)


def set_row_label_style(ws, row):
    ws.cell(row, 1).font = Font(name="Calibri", size=11, bold=True)
    clear_cell_fill(ws.cell(row, 1))


def clear_mcm_sheet_fills(ws):
    for row in ws.iter_rows():
        for cell in row:
            clear_cell_fill(cell)


def is_mcm_full_summary_label(value):
    text = str(value or "").strip()
    if text in {
        "Client ID",
        "GS ID",
        "Mapped Read Count",
        "total_read_count",
        "percent_reads_unmapped",
        "Comments",
    }:
        return True
    return text.startswith("MHC-") and " Haplotype " in text


def mcm_allele_name_font(value):
    families = mcm_families(value)
    if len(families) == 1:
        style = mcm_style_for_family(families[0])
        if style:
            return Font(name="Calibri", size=11, color=style["font"], bold=False)
    return Font(name="Calibri", size=11, bold=False)


def apply_mcm_summary_sheet_format(ws, custom_sort=False):
    clear_mcm_sheet_fills(ws)
    ws.column_dimensions["A"].width = MCM_CUSTOM_SORT_COLUMN_A_WIDTH if custom_sort else MCM_ABBREVIATED_COLUMN_A_WIDTH
    for cell in ws[1]:
        cell.font = Font(name="Calibri", size=12 if custom_sort else 11, bold=True)
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    section_labels = {
        "MHC homozygous MCM animals",
        "MHC heterozygous  MCM animals",
        "MHC recombinant  MCM animals",
        "Need to Repeat",
    }
    for row in range(2, ws.max_row + 1):
        first = ws.cell(row, 1).value
        if first in section_labels:
            ws.cell(row, 1).font = Font(name="Arial", size=14, bold=True)
            ws.cell(row, 1).alignment = Alignment(horizontal="left", vertical="center")
            continue
        if first not in (None, ""):
            ws.cell(row, 1).font = Font(name="Calibri", size=11, bold=True)
            ws.cell(row, 1).alignment = Alignment(horizontal="center", vertical="center")


def apply_mcm_full_sheet_format(ws):
    clear_mcm_sheet_fills(ws)
    ws.column_dimensions["A"].width = MCM_FULL_COLUMN_A_WIDTH
    for row in range(1, ws.max_row + 1):
        cell = ws.cell(row, 1)
        if cell.value not in (None, ""):
            if cell.value in MCM_ALLELE_SECTION_ORDER:
                cell.font = Font(name="Calibri", size=14, bold=True)
            elif is_mcm_full_summary_label(cell.value):
                cell.font = Font(name="Calibri", size=11, bold=True)
            else:
                cell.font = mcm_allele_name_font(cell.value)
            cell.alignment = Alignment(horizontal="left", vertical="center", wrap_text=True)


def ordered_loci_from_calls(calls_by_sample_locus):
    seen = set()
    ordered = []
    for locus in MCM_REPORT_LOCI:
        if any(report_call_for_locus(calls, locus) for calls in calls_by_sample_locus.values()):
            ordered.append(locus)
            seen.add(locus)
    for calls in calls_by_sample_locus.values():
        for locus in calls:
            normalized = summary_locus_for_call(locus)
            if normalized not in seen:
                ordered.append(normalized)
                seen.add(normalized)
    return ordered if ordered else MCM_REPORT_LOCI


def summary_locus_for_call(locus):
    if locus in ("MHC-DQA", "MHC-DQB"):
        return "MHC-DQ"
    if locus in ("MHC-DPA", "MHC-DPB"):
        return "MHC-DP"
    return locus


def report_call_for_locus(locus_calls, locus):
    if not locus_calls:
        return None
    if locus in locus_calls:
        return locus_calls.get(locus)
    if locus in ("MHC-DQA", "MHC-DQB", "MHC-DQ"):
        return locus_calls.get("MHC-DQ") or locus_calls.get("MHC-DQA") or locus_calls.get("MHC-DQB")
    if locus in ("MHC-DPA", "MHC-DPB", "MHC-DP"):
        return locus_calls.get("MHC-DP") or locus_calls.get("MHC-DPA") or locus_calls.get("MHC-DPB")
    return None


def call_value(call, index):
    if not call:
        return None
    value = call.get(f"haplotype{index}")
    if value is None:
        return None
    text = str(value).strip()
    return text if text else None


def inferred_homozygous_family(locus_calls, loci):
    families = []
    saw_called_locus = False
    for locus in loci:
        call = report_call_for_locus(locus_calls, locus)
        if not call:
            continue
        first = call_value(call, 1)
        second = call_value(call, 2)
        first_family = mcm_family(first)
        second_family = mcm_family(second)
        if first_family:
            saw_called_locus = True
            if first_family not in families:
                families.append(first_family)
        if second and second != "-":
            if not second_family:
                return None
            if second_family not in families:
                families.append(second_family)
        if isinstance(first, str) and first.startswith("ERR:"):
            return None
        if isinstance(second, str) and second.startswith("ERR:"):
            return None
    if saw_called_locus and len(families) == 1:
        return families[0]
    return None


def report_call_value(locus_calls, locus, index, loci):
    call = report_call_for_locus(locus_calls, locus)
    value = call_value(call, index)
    if index == 2 and value == "-":
        family = inferred_homozygous_family(locus_calls, loci)
        first = call_value(call, 1)
        if family and mcm_family(first) == family:
            return first
    return value


def whole_animal_haplotype(locus_calls, index, loci):
    families = []
    saw_nonempty = False
    for locus in loci:
        value = report_call_value(locus_calls, locus, index, loci)
        if value and value != "-":
            saw_nonempty = True
        family = mcm_family(value)
        if family and family not in families:
            families.append(family)
    if not saw_nonempty:
        return "?"
    if len(families) == 1:
        return families[0]
    if len(families) > 1:
        return "rec" + "".join(families)
    return "?"


def haplotype_comments(locus_calls):
    comments = []
    for locus in sorted(locus_calls):
        call = locus_calls[locus]
        status = call.get("status")
        notes = str(call.get("notes") or "").strip()
        values = [call_value(call, 1), call_value(call, 2)]
        if any(isinstance(value, str) and value.startswith("ERR:") for value in values if value):
            comments.append(f"{locus}: {'/'.join(value for value in values if value)}")
        elif status not in (None, "", "called"):
            comments.append(f"{locus}: {status}")
        if notes:
            comments.append(f"{locus}: {notes}")
    return "; ".join(comments)


def mcm_custom_sort_group(locus_calls, loci):
    h1 = whole_animal_haplotype(locus_calls, 1, loci)
    h2 = whole_animal_haplotype(locus_calls, 2, loci)
    comments = haplotype_comments(locus_calls)
    if h1 == "?" or h2 == "?" or "ERR:" in comments:
        return "Need to Repeat"
    if str(h1).startswith("rec") or str(h2).startswith("rec"):
        return "MHC recombinant  MCM animals"
    if h1 == h2:
        return "MHC homozygous MCM animals"
    return "MHC heterozygous  MCM animals"


def mcm_summary_values(sample, sample_stats, calls_by_sample_locus, loci):
    locus_calls = calls_by_sample_locus.get(sample, {})
    values = [
        sample,
        sample,
        read_count_for_sample(sample_stats, sample),
        whole_animal_haplotype(locus_calls, 1, loci),
        whole_animal_haplotype(locus_calls, 2, loci),
        None,
    ]
    for locus, _label in MCM_SUMMARY_DISPLAY_LOCI:
        values.append(report_call_value(locus_calls, locus, 1, loci))
    values.append(None)
    for locus, _label in MCM_SUMMARY_DISPLAY_LOCI:
        values.append(report_call_value(locus_calls, locus, 2, loci))
    values.append(haplotype_comments(locus_calls) or None)
    return values


def pipe_metadata(genotype):
    fields = {}
    parts = str(genotype or "").strip().split("|")
    for part in parts[1:]:
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key:
            fields[key] = value
    return fields


def compact_genotype_identifier(genotype):
    text = str(genotype or "").strip()
    return text.split("|", 1)[0].strip() if "|" in text else text


def mafa_display_allele_name(value):
    text = str(value or "").strip()
    if text.startswith("Mafa-") and "_" in text:
        prefix, suffix = text.split("_", 1)
        return f"{prefix}*{suffix}"
    return text


def compact_genotype_label(genotype):
    metadata = pipe_metadata(genotype)
    alleles = [
        mafa_display_allele_name(item)
        for item in metadata.get("alleles", "").split(",")
        if item.strip()
    ]
    if alleles:
        return "/".join(alleles)
    return compact_genotype_identifier(genotype)


def genotype_comment_text(genotype):
    text = str(genotype or "").strip()
    if "|" in text:
        return text
    return None


def source_locus_tokens(genotype):
    metadata = pipe_metadata(genotype)
    raw = metadata.get("source_loci") or metadata.get("source_locus") or metadata.get("haplotype_groups") or ""
    return [
        item.strip().upper()
        for item in re.split(r"[,;/]", raw)
        if item.strip()
    ]


def mcm_allele_section_from_metadata(genotype):
    tokens = source_locus_tokens(genotype)
    if not tokens:
        return None
    if any(token.endswith("F") or token == "MHC-F" for token in tokens):
        return "Mafa-F alleles"
    if any(token.endswith("G") or token == "MHC-G" for token in tokens):
        return "Mafa-G alleles"
    if any("AG" in token for token in tokens):
        return "Mafa-AG alleles"
    if any(token.endswith("A1") or token == "MHC-A1" for token in tokens):
        return "Mafa-A major alleles"
    if any(re.search(r"A[2456]$", token) or token in {"MHC-A2", "MHC-A4", "MHC-A5", "MHC-A6"} for token in tokens):
        return "Mafa-A minor alleles"
    if any("70" in token for token in tokens):
        return "Mafa-70 alleles"
    if any(token.endswith("E") or token == "MHC-E" for token in tokens):
        return "Mafa-E alleles"
    if any(token.endswith("B") or token == "MHC-B" for token in tokens):
        return "Mafa-B alleles"
    if any("DR" in token for token in tokens):
        return "Mafa-DRB alleles"
    if any("DQA" in token or "DQB" in token or token == "MHC-DQ" for token in tokens):
        return "Mafa-DQA/DQB alleles"
    if any("DPA" in token or "DPB" in token or token == "MHC-DP" for token in tokens):
        return "Mafa-DPA/DPB alleles"
    return None


def mcm_allele_section_label(genotype):
    metadata_section = mcm_allele_section_from_metadata(genotype)
    if metadata_section:
        return metadata_section
    text = str(genotype or "").strip()
    if text.startswith("01_"):
        return "Mafa-F alleles"
    if text.startswith("02_"):
        return "Mafa-G alleles"
    if text.startswith("04_") or text.startswith("AG_"):
        return "Mafa-AG alleles"
    if text.startswith("05_") or re.match(r"^A1_", text):
        return "Mafa-A major alleles"
    if text.startswith("06_") or re.match(r"^A[245]_", text):
        return "Mafa-A minor alleles"
    if text.startswith("07_") or text.startswith("10_"):
        return "Mafa-70 alleles"
    if text.startswith("11_") or text.startswith("E_"):
        return "Mafa-E alleles"
    if text.startswith("12_") or text.startswith("B") or text.startswith("I_"):
        return "Mafa-B alleles"
    if text.startswith("13_"):
        return "Mafa-DRB alleles"
    if text.startswith("14_"):
        return "Mafa-DQA/DQB alleles"
    if text.startswith("15_"):
        return "Mafa-DPA/DPB alleles"
    return "Mafa-DPA/DPB alleles"


def mcm_locus_for_allele_section(section):
    if section in {
        "Mafa-F alleles",
        "Mafa-G alleles",
        "Mafa-AG alleles",
        "Mafa-A major alleles",
        "Mafa-A minor alleles",
        "Mafa-70 alleles",
        "Mafa-E alleles",
    }:
        return "MHC-A"
    if section == "Mafa-B alleles":
        return "MHC-B"
    if section == "Mafa-DRB alleles":
        return "MHC-DRB"
    if section == "Mafa-DQA/DQB alleles":
        return "MHC-DQ"
    if section == "Mafa-DPA/DPB alleles":
        return "MHC-DP"
    return None


def sample_families_for_locus(locus_calls, locus):
    call = report_call_for_locus(locus_calls, locus)
    families = []
    for index in (1, 2):
        family = mcm_family(call_value(call, index))
        if family and family not in families:
            families.append(family)
    return families


def choose_count_style_family(genotype, locus_calls, section):
    genotype_families = mcm_families(genotype)
    if not genotype_families:
        return None
    locus = mcm_locus_for_allele_section(section)
    sample_families = sample_families_for_locus(locus_calls, locus)
    intersection = [family for family in MCM_FAMILIES if family in genotype_families and family in sample_families]
    if intersection:
        return intersection[0]
    if len(genotype_families) == 1:
        return genotype_families[0]
    return None


def apply_genotype_count_cell_style(cell, genotype, locus_calls, section):
    clear_cell_fill(cell)
    if cell.value in (None, ""):
        return
    family = choose_count_style_family(genotype, locus_calls, section)
    if family:
        style = mcm_style_for_family(family)
        cell.font = Font(name="Calibri", size=11, color=style.get("font", "000000"), bold=True)
    else:
        cell.font = Font(name="Calibri", size=11, bold=True)


def write_genotype_label_cell(ws, row, genotype):
    cell = ws.cell(row, 1)
    cell.value = compact_genotype_label(genotype)
    comment = genotype_comment_text(genotype)
    if comment:
        cell.comment = Comment(comment, "Lungfish")


def report_percent_value(value):
    if value is None or value == "":
        return "0%"
    try:
        number = float(value)
    except (TypeError, ValueError):
        text = str(value).strip()
        return text if text.endswith("%") else text
    if number.is_integer():
        return f"{int(number)}%"
    return f"{number:g}%"


def report_locus_percent_overrides(values):
    formatted = []
    for item in values or []:
        text = str(item or "").strip()
        if not text:
            continue
        if "=" not in text:
            formatted.append(text)
            continue
        locus, percent = text.split("=", 1)
        formatted.append(f"{locus.strip()}={report_percent_value(percent.strip())}")
    return "; ".join(formatted) if formatted else "None"


def write_interpretation_guide(ws, args, stats, haplotype_analysis, haplotype_definition):
    assay = (
        (haplotype_analysis or {}).get("assayID")
        or (haplotype_definition or {}).get("assayID")
        or ""
    )
    definition = (
        (haplotype_analysis or {}).get("definitionSetID")
        or (haplotype_definition or {}).get("id")
        or ""
    )
    rows = [
        ["Field", "Interpretation"],
        ["Client ID", "Client-provided sample identifier."],
        ["GS ID", "Genotyping sample identifier used in the run."],
        ["Mapped Read Count", "Filtered exact-match read count retained for the sample."],
        ["Haplotype 1 / Haplotype 2", "Whole-animal MCM haplotype assignment derived from per-locus calls."],
        ["recM", "Recombinant or mixed-family assignment across reported loci."],
        ["?", "No confident whole-animal haplotype assignment."],
        [None, None],
        ["Haplotype assay", assay],
        ["Haplotype definition", definition],
        ["Haplotype min reads", display_value(stats.get("minSupport"))],
        ["Haplotype min sample percent", report_percent_value(stats.get("haplotypeMinSamplePercent"))],
        ["Haplotype min locus percent", report_percent_value(stats.get("haplotypeMinLocusPercent"))],
        ["Haplotype locus percent overrides", report_locus_percent_overrides(stats.get("haplotypeMinLocusPercentOverrides"))],
        ["Haplotype filtering scope", "Read thresholds are used for haplotype assignment only; genotyping worksheets retain all observed reads."],
        ["Primary workbook", getattr(args, "primary_workbook", None) or ""],
        ["Report command", getattr(args, "provenance_command", None) or ""],
    ]
    for row in rows:
        ws.append(row)
    apply_basic_sheet_format(ws, auto_filter=False)


def definition_locus_rows(haplotype_definition):
    rows = []
    for locus in haplotype_definition.get("locusDefinitions", []) or []:
        locus_name = locus.get("sourceLocus") or locus.get("locus") or ""
        haplotypes = locus.get("haplotypes", []) or []
        name_by_family = {family: [] for family in MCM_FAMILIES}
        alleles_by_family = {family: [] for family in MCM_FAMILIES}
        for haplotype in haplotypes:
            name = haplotype.get("name")
            family = mcm_family(name)
            if not name or family not in name_by_family:
                continue
            name_by_family[family].append(str(name))
            alleles = [str(item) for item in haplotype.get("diagnosticAlleles", []) if item]
            alleles_by_family[family].extend(alleles)
        rows.append((locus_name, name_by_family, alleles_by_family))
    return rows


def write_mcm_alleles_per_haplotype(ws, haplotype_definition):
    ws.append(["Haplotype"] + MCM_FAMILIES)
    for locus_name, name_by_family, alleles_by_family in definition_locus_rows(haplotype_definition):
        ws.append([locus_name] + ["\n".join(name_by_family[family]) or None for family in MCM_FAMILIES])
        ws.append([f"{locus_name} diagnostic alleles"] + ["\n".join(alleles_by_family[family]) or None for family in MCM_FAMILIES])
    if ws.max_row == 1:
        ws.append(["No haplotype definition rows found"] + [None for _ in MCM_FAMILIES])
    apply_basic_sheet_format(ws, auto_filter=False)
    clear_mcm_sheet_fills(ws)
    for row in range(2, ws.max_row + 1):
        for col, family in enumerate(MCM_FAMILIES, start=2):
            value = ws.cell(row, col).value
            if value:
                apply_haplotype_cell_style(ws.cell(row, col), family)


def abbreviated_headers(loci):
    return (
        ["Client ID", "GS ID", "Mapped Read Count", "Haplotype 1", "Haplotype 2", None]
        + [f"{label} Haplotype 1" for _locus, label in MCM_SUMMARY_DISPLAY_LOCI]
        + [None]
        + [f"{label} Haplotype 2" for _locus, label in MCM_SUMMARY_DISPLAY_LOCI]
        + ["Comments"]
    )


def read_count_for_sample(sample_stats, sample):
    row = sample_stats.get(sample, {})
    return display_value(
        row.get("passed_alignments")
        or row.get("passed_unique_reads")
        or row.get("sample_unique_retained_reads")
    )


def write_abbreviated_haplotypes(ws, samples, sample_stats, calls_by_sample_locus, loci):
    headers = abbreviated_headers(loci)
    ws.append(headers)
    for sample in samples:
        ws.append(mcm_summary_values(sample, sample_stats, calls_by_sample_locus, loci))
    apply_basic_sheet_format(ws, auto_filter=False)
    apply_mcm_summary_sheet_format(ws)
    for row in range(2, ws.max_row + 1):
        for col in range(4, ws.max_column):
            apply_haplotype_cell_style(ws.cell(row, col), ws.cell(row, col).value)


def write_full_sequencing_results(ws, samples, sample_stats, genotype_counts, ordered_genotypes, calls_by_sample_locus, loci):
    ws.cell(1, 1).value = "Client ID"
    ws.cell(2, 1).value = "GS ID"
    ws.cell(3, 1).value = "Mapped Read Count"
    for offset, sample in enumerate(samples, start=4):
        ws.cell(1, offset).value = sample
        ws.cell(2, offset).value = sample
        ws.cell(3, offset).value = read_count_for_sample(sample_stats, sample)
    for row in range(1, 4):
        set_row_label_style(ws, row)

    row_index = 4
    ws.cell(row_index, 1).value = "total_read_count"
    for offset, sample in enumerate(samples, start=4):
        ws.cell(row_index, offset).value = display_value(sample_stats.get(sample, {}).get("sample_total_reads"))
    set_row_label_style(ws, row_index)
    row_index += 1
    ws.cell(row_index, 1).value = "percent_reads_unmapped"
    for offset, sample in enumerate(samples, start=4):
        retained = as_number(sample_stats.get(sample, {}).get("sample_unique_retained_percent"))
        ws.cell(row_index, offset).value = None if retained is None else max(0, 100 - retained)
    set_row_label_style(ws, row_index)
    row_index += 1

    summary_haplotype_rows = []
    for locus in MCM_FULL_SUMMARY_LOCI:
        for index in (1, 2):
            ws.cell(row_index, 1).value = f"{locus} Haplotype {index}"
            set_row_label_style(ws, row_index)
            for offset, sample in enumerate(samples, start=4):
                locus_calls = calls_by_sample_locus.get(sample, {})
                value = report_call_value(locus_calls, locus, index, loci)
                ws.cell(row_index, offset).value = value
            summary_haplotype_rows.append(row_index)
            row_index += 1

    while row_index < 20:
        row_index += 1
    ws.cell(row_index, 1).value = "Comments"
    ws.cell(row_index, 2).value = "Subtotal"
    ws.cell(row_index, 3).value = "# Obs."
    set_row_label_style(ws, row_index)
    for offset, sample in enumerate(samples, start=4):
        ws.cell(row_index, offset).value = haplotype_comments(calls_by_sample_locus.get(sample, {})) or None
    row_index += 1

    observed_genotypes_by_section = {section: [] for section in MCM_ALLELE_SECTION_ORDER}
    for genotype in ordered_genotypes:
        if not any(genotype_counts.get(sample, {}).get(genotype, 0) > 0 for sample in samples):
            continue
        section = mcm_allele_section_label(genotype)
        observed_genotypes_by_section.setdefault(section, []).append(genotype)

    allele_row_info = []
    for section in MCM_ALLELE_SECTION_ORDER:
        section_genotypes = observed_genotypes_by_section.get(section, [])
        if not section_genotypes:
            continue
        ws.cell(row_index, 1).value = section
        set_row_label_style(ws, row_index)
        row_index += 1
        for genotype in section_genotypes:
            write_genotype_label_cell(ws, row_index, genotype)
            total = 0
            observed = 0
            for offset, sample in enumerate(samples, start=4):
                count = genotype_counts.get(sample, {}).get(genotype, 0)
                if count > 0:
                    ws.cell(row_index, offset).value = count
                    total += count
                    observed += 1
            ws.cell(row_index, 2).value = total
            ws.cell(row_index, 3).value = observed
            allele_row_info.append((row_index, genotype, section))
            row_index += 1
    for section in sorted(observed_genotypes_by_section):
        if section in MCM_ALLELE_SECTION_ORDER or not observed_genotypes_by_section.get(section):
            continue
        ws.cell(row_index, 1).value = section
        set_row_label_style(ws, row_index)
        row_index += 1
        for genotype in observed_genotypes_by_section[section]:
            write_genotype_label_cell(ws, row_index, genotype)
            total = 0
            observed = 0
            for offset, sample in enumerate(samples, start=4):
                count = genotype_counts.get(sample, {}).get(genotype, 0)
                if count > 0:
                    ws.cell(row_index, offset).value = count
                    total += count
                    observed += 1
            ws.cell(row_index, 2).value = total
            ws.cell(row_index, 3).value = observed
            allele_row_info.append((row_index, genotype, section))
            row_index += 1

    apply_basic_sheet_format(ws, freeze_panes="D21", auto_filter=False)
    apply_mcm_full_sheet_format(ws)
    for row in summary_haplotype_rows:
        for col in range(4, ws.max_column + 1):
            apply_haplotype_cell_style(ws.cell(row, col), ws.cell(row, col).value)
    for row, genotype, section in allele_row_info:
        for col, sample in enumerate(samples, start=4):
            apply_genotype_count_cell_style(
                ws.cell(row, col),
                genotype,
                calls_by_sample_locus.get(sample, {}),
                section,
            )


def write_custom_sort(ws, samples, sample_stats, calls_by_sample_locus, loci):
    headers = abbreviated_headers(loci)
    headers[2] = "Mapped Read Counts"
    ws.append(headers)
    group_order = [
        "MHC homozygous MCM animals",
        "MHC heterozygous  MCM animals",
        "MHC recombinant  MCM animals",
        "Need to Repeat",
    ]
    grouped = {label: [] for label in group_order}
    for sample in samples:
        locus_calls = calls_by_sample_locus.get(sample, {})
        grouped[mcm_custom_sort_group(locus_calls, loci)].append(sample)
    for label in group_order:
        group_samples = grouped[label]
        if not group_samples:
            continue
        if ws.max_row > 1:
            ws.append([None for _ in headers])
        ws.append([label] + [None for _ in headers[1:]])
        sorted_samples = sorted(
            group_samples,
            key=lambda sample: (
                whole_animal_haplotype(calls_by_sample_locus.get(sample, {}), 1, loci),
                whole_animal_haplotype(calls_by_sample_locus.get(sample, {}), 2, loci),
                sample,
            ),
        )
        for sample in sorted_samples:
            ws.append(mcm_summary_values(sample, sample_stats, calls_by_sample_locus, loci))
    apply_basic_sheet_format(ws, auto_filter=False)
    apply_mcm_summary_sheet_format(ws, custom_sort=True)
    for row in range(2, ws.max_row + 1):
        for col in range(4, ws.max_column):
            apply_haplotype_cell_style(ws.cell(row, col), ws.cell(row, col).value)
        if ws.cell(row, 1).value in grouped:
            for col in range(1, ws.max_column + 1):
                ws.cell(row, col).border = Border()


def build_mcm_client_current_workbook(args, genotype_rows, sample_rows, stats, haplotype_analysis, haplotype_definition):
    wb = Workbook()
    ws = wb.active
    ws.title = MCM_CLIENT_SHEET_NAMES[0]
    genotype_counts = load_genotype_counts(genotype_rows)
    samples = report_sample_names(sample_rows, genotype_counts)
    genotype_rows = rows_for_samples(genotype_rows, samples)
    sample_rows = rows_for_samples(sample_rows, samples)
    genotype_counts = load_genotype_counts(genotype_rows)
    sample_stats = load_sample_stats(sample_rows)
    calls_by_sample_locus = haplotype_calls_by_sample_locus(haplotype_analysis)
    loci = ordered_loci_from_calls(calls_by_sample_locus)
    ordered_genotypes = []
    seen = set()
    for name in reference_names(args.reference_fasta):
        if name not in seen:
            ordered_genotypes.append(name)
            seen.add(name)
    for row in genotype_rows:
        genotype = row.get("genotype")
        if genotype and genotype not in seen:
            ordered_genotypes.append(genotype)
            seen.add(genotype)

    write_interpretation_guide(ws, args, stats, haplotype_analysis, haplotype_definition)
    write_mcm_alleles_per_haplotype(wb.create_sheet(title=MCM_CLIENT_SHEET_NAMES[1]), haplotype_definition)
    write_abbreviated_haplotypes(wb.create_sheet(title=MCM_CLIENT_SHEET_NAMES[2]), samples, sample_stats, calls_by_sample_locus, loci)
    write_full_sequencing_results(
        wb.create_sheet(title=MCM_CLIENT_SHEET_NAMES[3]),
        samples,
        sample_stats,
        genotype_counts,
        ordered_genotypes,
        calls_by_sample_locus,
        loci,
    )
    write_custom_sort(wb.create_sheet(title=MCM_CLIENT_SHEET_NAMES[4]), samples, sample_stats, calls_by_sample_locus, loci)
    wb.active = 0
    return wb, 0


def write_audit_sheet(wb, title, comparison_ws, sample_cols, allele_rows, matched_by_row_sample, comparison_name, analysis_name):
    ws = wb.create_sheet(title=safe_sheet_title(wb, title, "Audit"))
    headers = [
        "sample",
        "row",
        "expected_call",
        f"{comparison_name}_count",
        f"{analysis_name}_count",
        f"recovered_{comparison_name}_positive",
        "tokens",
        "matched_genotypes",
    ]
    ws.append(headers)
    audit_rows = 0
    comparison_sample_cols = {sample: col for col, sample in sample_columns(comparison_ws)}
    for row in allele_rows:
        expected_call = comparison_ws.cell(row, 1).value
        for col, sample in sample_cols:
            comparison_col = comparison_sample_cols.get(sample, col)
            comparison_count = as_number(comparison_ws.cell(row, comparison_col).value) or 0
            analysis_count, names, tokens = matched_by_row_sample.get((row, sample), (0, [], []))
            if analysis_count <= 0:
                continue
            recovered = None
            if comparison_count > 0:
                recovered = "yes" if analysis_count > 0 else "no"
            ws.append([
                sample,
                row,
                expected_call,
                comparison_count if comparison_count > 0 else None,
                analysis_count if analysis_count > 0 else None,
                recovered,
                ",".join(tokens),
                ";".join(names),
            ])
            audit_rows += 1
    style_tabular_sheet(ws)
    return ws, audit_rows


def build_template_workbook(args, genotype_headers, genotype_rows, sample_headers, sample_rows, stats, haplotype_analysis):
    wb, analysis_ws, comparison_ws = copied_template_workbook(
        args.comparison_workbook,
        args.analysis_name,
        args.comparison_name,
    )
    genotype_counts = load_genotype_counts(genotype_rows)
    samples = report_sample_names(sample_rows, genotype_counts)
    genotype_rows = rows_for_samples(genotype_rows, samples)
    sample_rows = rows_for_samples(sample_rows, samples)
    genotype_counts = load_genotype_counts(genotype_rows)
    sample_stats = load_sample_stats(sample_rows)
    sample_cols, allele_rows, matched = fill_analysis_sheet(analysis_ws, genotype_counts, sample_stats, samples)
    fill_haplotype_rows(analysis_ws, sample_cols, haplotype_analysis)
    write_csv_sheet(wb, f"{args.analysis_name} Long Summary", genotype_headers, genotype_rows)
    write_csv_sheet(wb, f"{args.analysis_name} Sample Summary", sample_headers, sample_rows)
    write_haplotype_sheet(wb, haplotype_analysis)
    _, audit_rows = write_audit_sheet(
        wb,
        f"{args.comparison_name} Audit",
        comparison_ws,
        sample_cols,
        allele_rows,
        matched,
        args.comparison_name,
        args.analysis_name,
    )
    write_stats_sheet(wb, stats)
    wb.active = 0
    return wb, audit_rows


def build_generic_workbook(args, genotype_headers, genotype_rows, sample_headers, sample_rows, stats, haplotype_analysis):
    wb = Workbook()
    ws = wb.active
    ws.title = safe_sheet_title(wb, args.analysis_name, "ONT08")
    genotype_counts = load_genotype_counts(genotype_rows)
    samples = report_sample_names(sample_rows, genotype_counts)
    genotype_rows = rows_for_samples(genotype_rows, samples)
    sample_rows = rows_for_samples(sample_rows, samples)
    genotype_counts = load_genotype_counts(genotype_rows)
    sample_stats = load_sample_stats(sample_rows)
    ordered_genotypes = []
    seen = set()
    for name in reference_names(args.reference_fasta):
        if name not in seen:
            ordered_genotypes.append(name)
            seen.add(name)
    for row in genotype_rows:
        genotype = row.get("genotype")
        if genotype and genotype not in seen:
            ordered_genotypes.append(genotype)
            seen.add(genotype)

    ws.append(["Animal ID", None, None] + samples)
    ws.append(["GS ID", "Total", "Average"] + samples)
    ws.append(["Filtered exact-match read count", None, None] + [display_value(sample_stats.get(sample, {}).get("passed_alignments")) for sample in samples])
    ws.append([])
    ws.append([])
    for locus in haplotype_loci_for_report(haplotype_analysis):
        ws.append([f"{locus} Haplotype 1", None, None] + [None for _sample in samples])
        ws.append([f"{locus} Haplotype 2", None, None] + [None for _sample in samples])
    ws.append(["Comments", "Subtotal", "# Obs."] + [None for _sample in samples])
    ws.append(["Genotype", "Total", "# Obs."] + samples)
    sample_cols = [(index + 4, sample) for index, sample in enumerate(samples)]
    fill_haplotype_rows(ws, sample_cols, haplotype_analysis)
    for genotype in ordered_genotypes:
        if not any(genotype_counts.get(sample, {}).get(genotype, 0) > 0 for sample in samples):
            continue
        row_index = ws.max_row + 1
        values = [genotype, None, None]
        for sample in samples:
            count = genotype_counts.get(sample, {}).get(genotype, 0)
            values.append(count if count > 0 else None)
        ws.append(values)
        fill_subtotal_observed_values(ws, [row_index], sample_cols)
    fill_read_count_summary_values(ws, 3, sample_cols)
    style_tabular_sheet(ws)
    write_csv_sheet(wb, f"{args.analysis_name} Long Summary", genotype_headers, genotype_rows)
    write_csv_sheet(wb, f"{args.analysis_name} Sample Summary", sample_headers, sample_rows)
    write_haplotype_sheet(wb, haplotype_analysis)
    write_stats_sheet(wb, stats)
    wb.active = 0
    return wb, 0


def write_provenance(args, start_time, started_at, completed_at, audit_rows):
    mode = "mcm-client-current" if args.client_current_workbook else "standard-report"
    inputs = [
        file_record(args.genotypes_csv, "input"),
        file_record(args.samples_csv, "input"),
        file_record(args.stats_json, "input"),
        file_record(args.reference_fasta, "input"),
        file_record(args.barcode_definitions, "input"),
    ]
    if args.comparison_workbook:
        inputs.append(file_record(args.comparison_workbook, "comparison"))
    if args.haplotype_analysis_json:
        inputs.append(file_record(args.haplotype_analysis_json, "analysis"))
    if args.haplotype_definition_json:
        inputs.append(file_record(args.haplotype_definition_json, "haplotype-definition"))
    if args.primary_workbook:
        inputs.append(file_record(args.primary_workbook, "primary-workbook"))
    payload = {
        "toolName": "lungfish fastq ont-barcode-genotype workbook report",
        "toolVersion": "1",
        "mode": mode,
        "argv": sys.argv,
        "reproducibleCommand": args.provenance_command or " ".join(sys.argv),
        "options": vars(args),
        "resolvedDefaults": {
            "analysisName": args.run_name,
            "comparisonName": "Illumina-31262",
            "haplotypeAnalysisJSON": None,
            "clientCurrentWorkbook": False,
            "haplotypeDefinitionJSON": None,
            "primaryWorkbook": None,
        },
        "runtimeIdentity": {
            "python": sys.version,
            "platform": platform.platform(),
            "openpyxl": openpyxl.__version__,
            "executable": sys.executable,
        },
        "inputs": inputs,
        "outputs": [
            file_record(args.output_xlsx, "report"),
            {"path": args.provenance_json, "role": "provenance", "exists": False},
        ],
        "primaryWorkbook": args.primary_workbook,
        "outputWorkbook": args.output_xlsx,
        "auditRows": audit_rows,
        "exitStatus": 0,
        "wallClockSeconds": time.time() - start_time,
        "stderr": "",
        "startedAt": started_at,
        "completedAt": completed_at,
    }
    with open(args.provenance_json, "w") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    payload["outputs"] = [
        file_record(args.output_xlsx, "report"),
        file_record(args.provenance_json, "provenance"),
    ]
    with open(args.provenance_json, "w") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def main():
    args = parse_args()
    start_time = time.time()
    started_at = utc_now()
    os.makedirs(os.path.dirname(args.output_xlsx) or ".", exist_ok=True)
    genotype_headers, genotype_rows = read_csv(args.genotypes_csv)
    sample_headers, sample_rows = read_csv(args.samples_csv)
    genotype_rows = assigned_sample_rows(genotype_rows)
    sample_rows = assigned_sample_rows(sample_rows)
    with open(args.stats_json) as handle:
        stats = json.load(handle)
    haplotype_analysis = load_haplotype_analysis(args.haplotype_analysis_json)

    if args.client_current_workbook:
        haplotype_definition = load_haplotype_definition(args.haplotype_definition_json)
        wb, audit_rows = build_mcm_client_current_workbook(
            args,
            genotype_rows,
            sample_rows,
            stats,
            haplotype_analysis,
            haplotype_definition,
        )
    elif args.comparison_workbook:
        wb, audit_rows = build_template_workbook(args, genotype_headers, genotype_rows, sample_headers, sample_rows, stats, haplotype_analysis)
    else:
        wb, audit_rows = build_generic_workbook(args, genotype_headers, genotype_rows, sample_headers, sample_rows, stats, haplotype_analysis)

    wb.save(args.output_xlsx)
    completed_at = utc_now()
    write_provenance(args, start_time, started_at, completed_at, audit_rows)
    summary = {
        "outputXLSX": args.output_xlsx,
        "provenanceJSON": args.provenance_json,
        "openpyxlVersion": openpyxl.__version__,
        "sheetNames": wb.sheetnames,
        "auditRows": audit_rows,
    }
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
"""#
