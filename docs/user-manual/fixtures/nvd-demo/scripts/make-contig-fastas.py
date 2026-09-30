#!/usr/bin/env python3
"""Write simulated per-sample contig FASTAs for the NVD demo fixture.

The demo BLAST table names four SARS-CoV-2 contigs across three samples but
ships no contig sequences, so BLAST Verify has nothing to submit. This script
cuts each contig from the SARS-CoV-2 reference MN908947.3, at the length the
table records (qlen), and writes them where the importer looks:
results/02_human_viruses/03_human_virus_results/<sample>.human_virus.fasta.

The output is deterministic: each contig comes from a fixed offset, and a few
evenly spaced substitutions bring its identity to the top hit's pident. The
sequences are simulated; they only stand in for assembled contigs.

Usage: make-contig-fastas.py <MN908947.3 FASTA or .fa.gz> [results-dir]
"""
import csv
import gzip
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
OFFSETS = {  # contig start in MN908947.3 (0-based), one region per contig
    ("SampleA", "NODE_1_length_500_cov_10.0"): 21_563,   # spike, start of S
    ("SampleA", "NODE_2_length_300_cov_5.0"): 28_274,    # nucleocapsid
    ("SampleB", "NODE_1_length_400_cov_8.0"): 13_442,   # ORF1b
    ("SampleC", "NODE_5_length_200_cov_2.0"): 26_523,   # membrane
}
SWAP = {"A": "G", "G": "A", "C": "T", "T": "C"}


def read_fasta(path: Path) -> str:
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt") as handle:
        return "".join(line.strip() for line in handle if not line.startswith(">")).upper()


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    reference = read_fasta(Path(argv[1]))
    results = Path(argv[2]) if len(argv) > 2 else HERE / "results"
    table = next((results / "05_labkey_bundling").glob("*_blast_concatenated.csv"))
    best = {}
    with table.open() as handle:
        for row in csv.DictReader(handle):
            key = (row["sample_id"], row["qseqid"])
            if key not in best or float(row["bitscore"]) > float(best[key]["bitscore"]):
                best[key] = row
    out_dir = results / "02_human_viruses" / "03_human_virus_results"
    out_dir.mkdir(parents=True, exist_ok=True)
    by_sample = {}
    for (sample, contig), row in sorted(best.items()):
        length = int(row["qlen"])
        start = OFFSETS[(sample, contig)]
        seq = list(reference[start:start + length])
        mismatches = round(length * (100 - float(row["pident"])) / 100)
        for i in range(mismatches):
            pos = (i + 1) * length // (mismatches + 1)
            seq[pos] = SWAP.get(seq[pos], "A")
        by_sample.setdefault(sample, []).append((contig, "".join(seq)))
    for sample, contigs in by_sample.items():
        path = out_dir / f"{sample}.human_virus.fasta"
        with path.open("w") as handle:
            for contig, seq in contigs:
                handle.write(f">{contig}\n")
                for i in range(0, len(seq), 60):
                    handle.write(seq[i:i + 60] + "\n")
        print(path)


if __name__ == "__main__":
    main(sys.argv)
