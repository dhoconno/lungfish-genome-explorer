#!/usr/bin/env python3
"""Cut a small barcoded Oxford Nanopore run folder out of the six PRJEB62796
runs in source/ (see fetch.sh).

Each ENA run is one sample and one native barcode, uploaded by the submitters
with the barcode and adapter sequences still on every read (MinKNOW sorted the
reads into barcode folders but did not trim them). This script:

1. Reads each run and checks every read for its own barcode (up to 3
   mismatches within the first or last 120 bases, either strand).
2. Draws 1,000 reads that carry the barcode per run, at a fixed seed, and writes
   them as two 500-read chunk files under ont-run/fastq_pass/barcodeNN/, the
   layout MinKNOW writes.
3. Draws 34 reads per run in which the barcode could not be found by sequence
   and writes the 204 of them under ont-run/fastq_pass/unclassified/. MinKNOW
   had assigned these reads to their samples by its own scoring; here they stand
   in for the reads a run leaves unclassified.
4. Writes 400 of each barcode's kept reads (2,400 in all), shuffled, as
   pooled/nrg1-pooled.fastq.gz for the demultiplexing procedure. The pool is
   capped so the file stays under the repository's 500 KB limit for docs/.

Gzip members are written with a zeroed timestamp so reruns reproduce the files
byte for byte.
"""
import gzip
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, 'source')
RUN_DIR = os.path.join(HERE, 'ont-run', 'fastq_pass')
POOLED = os.path.join(HERE, 'pooled', 'nrg1-pooled.fastq.gz')
PREFIX = 'nrg1'          # stands in for the flow cell id MinKNOW puts first
PER_BARCODE = 1000
CHUNK = 500
PER_UNCLASSIFIED = 34
POOL_PER_BARCODE = 400
SEED = 2026
WINDOW = 120
MAX_MISMATCHES = 3

# run, native barcode (SQK-NBD114-96 numbering), sample title on ENA
RUNS = [
    ('ERR12259924', 'barcode85', 'NB85', 'AACGGAGGAGTTAGTTGGATGATC', 'NRG1Amplicon_IPSCProgenitors_long'),
    ('ERR12259925', 'barcode86', 'NB86', 'AGGTGATCCCAACAAGCGTAAGTA', 'NRG1Amplicon_IPSCMacrophages_long'),
    ('ERR12259926', 'barcode87', 'NB87', 'TACATGCTCCTGTTGTTAGGGAGG', 'NRG1Amplicon_Monocytes_long'),
    ('ERR12259928', 'barcode89', 'NB89', 'ACAGCATCAATGTTTGGCTAGTTG', 'NRG1Amplicon_IPSCProgenitors_short'),
    ('ERR12259929', 'barcode90', 'NB90', 'GATGTAGAGGGTACGGTTTGAGGC', 'NRG1Amplicon_IPSCMacrophages_short'),
    ('ERR12259930', 'barcode91', 'NB91', 'GGCTCCATAGGAACTCACGCTACT', 'NRG1Amplicon_Monocytes_short'),
]


def rc(s):
    return s.translate(str.maketrans('ACGTN', 'TGCAN'))[::-1]


def found(window, query):
    L = len(query)
    for i in range(len(window) - L + 1):
        mm = 0
        for a, b in zip(window[i:i + L], query):
            if a != b:
                mm += 1
                if mm > MAX_MISMATCHES:
                    break
        if mm <= MAX_MISMATCHES:
            return True
    return False


def has_barcode(seq, barcode):
    head, tail = seq[:WINDOW], seq[-WINDOW:]
    for q in (barcode, rc(barcode)):
        if found(head, q) or found(tail, q):
            return True
    return False


def read_records(path):
    with gzip.open(path, 'rt') as fh:
        while True:
            lines = [fh.readline() for _ in range(4)]
            if not lines[0]:
                return
            yield tuple(line.rstrip('\n') for line in lines)


def write_gz(path, records):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with gzip.GzipFile(path, 'wb', mtime=0) as raw:
        for rec in records:
            raw.write(('\n'.join(rec) + '\n').encode())


rng = random.Random(SEED)
pooled = []
unclassified = []
summary = []
for acc, folder, nb, barcode, title in RUNS:
    with_bc, without_bc = [], []
    for rec in read_records(os.path.join(SOURCE, f'{acc}.fastq.gz')):
        (with_bc if has_barcode(rec[1].upper(), barcode) else without_bc).append(rec)
    total = len(with_bc) + len(without_bc)
    chosen = rng.sample(with_bc, PER_BARCODE)
    chosen_un = rng.sample(without_bc, PER_UNCLASSIFIED)
    for i in range(0, PER_BARCODE, CHUNK):
        write_gz(os.path.join(RUN_DIR, folder, f'{PREFIX}_pass_{folder}_{i // CHUNK}.fastq.gz'),
                 chosen[i:i + CHUNK])
    pooled.extend(chosen[:POOL_PER_BARCODE])
    unclassified.extend(chosen_un)
    bases = sum(len(r[1]) for r in chosen)
    summary.append((acc, folder, nb, title, total, len(with_bc), len(chosen), bases))
    print(f'{acc} {folder} ({nb}, {title}): {total} reads, {len(with_bc)} carry the barcode '
          f'({100 * len(with_bc) / total:.1f}%), kept {len(chosen)} ({bases} bases) '
          f'+ {len(chosen_un)} unclassified')

rng.shuffle(unclassified)
write_gz(os.path.join(RUN_DIR, 'unclassified', f'{PREFIX}_pass_unclassified_0.fastq.gz'), unclassified)
rng.shuffle(pooled)
write_gz(POOLED, pooled)
print(f'unclassified: {len(unclassified)} reads; pooled: {len(pooled)} reads')
