// ONTBarcodeDemuxGenotypingPipeline+Scripts.swift - Embedded Python script payloads for ONT demux genotyping
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ONTBarcodeDemuxGenotypingPipeline {
    public static func writeFilterScript(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try filterScript.write(to: url, atomically: true, encoding: .utf8)
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
