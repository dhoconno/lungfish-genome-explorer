#!/usr/bin/env python3
import argparse
import gzip
import json
import os
import sys
from collections import Counter

import pysam


IUPAC = {
    "A": {"A"},
    "C": {"C"},
    "G": {"G"},
    "T": {"T"},
    "U": {"T"},
    "R": {"A", "G"},
    "Y": {"C", "T"},
    "S": {"G", "C"},
    "W": {"A", "T"},
    "K": {"G", "T"},
    "M": {"A", "C"},
    "B": {"C", "G", "T"},
    "D": {"A", "G", "T"},
    "H": {"A", "C", "T"},
    "V": {"A", "C", "G"},
    "N": {"A", "C", "G", "T", "N"},
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Filter ONT amplicon genotyping alignments with pysam."
    )
    parser.add_argument("--sample-name", required=True)
    parser.add_argument("--input-bam", required=True)
    parser.add_argument("--reference-fasta", required=True)
    parser.add_argument("--output-bam", required=True)
    parser.add_argument("--require-both-end-softclips", action="store_true")
    parser.add_argument("--require-full-reference-span", action="store_true")
    parser.add_argument("--allow-indels", action="store_true")
    parser.add_argument("--max-mismatches", type=int, default=0)
    return parser.parse_args()


def open_text(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt")
    return open(path, "rt")


def load_fasta(path):
    sequences = {}
    name = None
    chunks = []
    with open_text(path) as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            if line.startswith(">"):
                if name is not None:
                    sequences[name] = "".join(chunks).upper().replace("U", "T")
                name = line[1:].split()[0]
                chunks = []
            else:
                chunks.append(line)
    if name is not None:
        sequences[name] = "".join(chunks).upper().replace("U", "T")
    return sequences


def consumes_reference(op):
    return op in (0, 2, 3, 7, 8)


def consumes_query(op):
    return op in (0, 1, 4, 7, 8)


def has_both_terminal_softclips(read):
    cigar = read.cigartuples or []
    cigar = [item for item in cigar if item[0] != 5]
    return len(cigar) >= 3 and cigar[0][0] == 4 and cigar[-1][0] == 4


def reference_span_is_full(read, reference_length):
    return read.reference_start == 0 and read.reference_end == reference_length


def query_matches_reference(query_base, reference_base):
    q = query_base.upper().replace("U", "T")
    r = reference_base.upper().replace("U", "T")
    allowed = IUPAC.get(r, {r})
    return q in allowed or "N" in allowed


def mismatch_count(read, reference_sequence):
    sequence = read.query_sequence or ""
    mismatches = 0
    query_pos = 0
    reference_pos = read.reference_start

    for op, length in read.cigartuples or []:
        if op in (0, 7, 8):
            for offset in range(length):
                qpos = query_pos + offset
                rpos = reference_pos + offset
                if qpos >= len(sequence) or rpos >= len(reference_sequence):
                    mismatches += 1
                    continue
                if not query_matches_reference(sequence[qpos], reference_sequence[rpos]):
                    mismatches += 1
            query_pos += length
            reference_pos += length
        elif op == 1:
            query_pos += length
        elif op in (2, 3):
            reference_pos += length
        elif op == 4:
            query_pos += length
        elif op in (5, 6):
            continue
        else:
            if consumes_query(op):
                query_pos += length
            if consumes_reference(op):
                reference_pos += length

    return mismatches


def passes(read, references, args):
    if read.is_unmapped:
        return False
    ref_name = read.reference_name
    reference_sequence = references.get(ref_name)
    if reference_sequence is None:
        return False
    if args.require_both_end_softclips and not has_both_terminal_softclips(read):
        return False
    if args.require_full_reference_span and not reference_span_is_full(read, len(reference_sequence)):
        return False
    return mismatch_count(read, reference_sequence) <= args.max_mismatches


def main():
    args = parse_args()
    references = load_fasta(args.reference_fasta)
    os.makedirs(os.path.dirname(args.output_bam) or ".", exist_ok=True)

    total = 0
    passed = 0
    counts = Counter()
    with pysam.AlignmentFile(args.input_bam, "rb") as source:
        with pysam.AlignmentFile(args.output_bam, "wb", header=source.header) as dest:
            for read in source.fetch(until_eof=True):
                total += 1
                if passes(read, references, args):
                    dest.write(read)
                    passed += 1
                    counts[read.reference_name] += 1

    pysam.index(args.output_bam)
    output_bai = args.output_bam + ".bai"
    payload = {
        "sampleName": args.sample_name,
        "inputBAM": args.input_bam,
        "outputBAM": args.output_bam,
        "outputBAI": output_bai,
        "totalAlignments": total,
        "passedAlignments": passed,
        "genotypeCounts": [
            {
                "genotype": genotype,
                "filteredIndelOnlyMappedReads": count,
            }
            for genotype, count in sorted(counts.items(), key=lambda item: (-item[1], item[0]))
        ],
    }
    print(json.dumps(payload, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"pysam ONT genotyping filter failed: {exc}", file=sys.stderr)
        raise