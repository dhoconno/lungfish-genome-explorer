#!/usr/bin/env python3
"""SIMULATED three-species 12S mixture. Cuts the MiFish-U amplicon (primer
site to primer site) out of the human, rhesus macaque, and cynomolgus macaque
mitochondrial genomes, then simulates merged Illumina-style amplicon reads from
each with wgsim (Heng Li, samtools project) at a fixed seed and mixes them at
known proportions.

Reads   ../primate-mito/primate-mito.fasta
Writes  SIMULATED-12S-mixture.amplicons.fasta   (the three templates)
        SIMULATED-12S-mixture.fastq.gz          (2,000 reads, both strands)
        SIMULATED-12S-mixture.truth.tsv         (species per read name)

The read names keep wgsim's form, <template>_<start>_<end>_<subs:indels:errors on
read 1>_<same for read 2>_<serial>/1, so the species and the number of
simulated errors in every read are readable from the name.

Environment: WGSIM points at the wgsim binary (default: wgsim on PATH).
"""
import gzip
import os
import random
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
MITO = os.path.join(HERE, os.pardir, 'primate-mito', 'primate-mito.fasta')
WGSIM = os.environ.get('WGSIM', 'wgsim')
BASENAME = 'SIMULATED-12S-mixture'

# Known truth. Order fixes the seeds and the mixing.
MIX = [
    # template label, genome key, scientific name, reads, wgsim seed
    ('human',      'Human_NC_012920.1',             'Homo sapiens',        1400, 12001),
    ('rhesus',     'RhesusMacaque_NC_005943.1',     'Macaca mulatta',       500, 12002),
    ('cynomolgus', 'CynomolgusMacaque_NC_012670.1', 'Macaca fascicularis',  100, 12003),
]
ERROR_RATE = 0.002      # wgsim -e, per-base substitution error
SHUFFLE_SEED = 12000

MIFISH_U_F = 'GTCGGTAAAACTCGTGCCAGC'
MIFISH_U_R = 'CATAGTGGGGTATCTAATCCCAGTTTG'


def read_fasta(path):
    seqs, name = {}, None
    for line in open(path):
        line = line.strip()
        if line.startswith('>'):
            name = line[1:]
            seqs[name] = []
        elif name:
            seqs[name].append(line)
    return {k: ''.join(v).upper() for k, v in seqs.items()}


def rc(s):
    return s.translate(str.maketrans('ACGTN', 'TGCAN'))[::-1]


def find_primer(genome, primer):
    best, best_mm = None, 99
    for i in range(len(genome) - len(primer) + 1):
        mm = sum(1 for a, b in zip(genome[i:i + len(primer)], primer) if a != b)
        if mm < best_mm:
            best_mm, best = mm, i
    return best, best_mm


genomes = read_fasta(MITO)
templates = []
with open(os.path.join(HERE, f'{BASENAME}.amplicons.fasta'), 'w') as fh:
    for label, key, latin, n, seed in MIX:
        g = genomes[key]
        f_start, f_mm = find_primer(g, MIFISH_U_F)
        r_start, r_mm = find_primer(g, rc(MIFISH_U_R))
        amplicon = g[f_start:r_start + len(MIFISH_U_R)]
        acc = key.split('_', 1)[1]
        fh.write(f'>{label} {latin} {acc}:{f_start + 1}-{r_start + len(MIFISH_U_R)} '
                 f'MiFish-U amplicon, primer-site mismatches F={f_mm} R={r_mm}\n{amplicon}\n')
        templates.append((label, latin, amplicon, n, seed))
        print(f'{label}: {len(amplicon)} bp amplicon at {acc}:{f_start + 1}-{r_start + len(MIFISH_U_R)}')

reads = []
truth = []
for label, latin, amplicon, n, seed in templates:
    tpl = os.path.join(HERE, f'.{label}.template.fa')
    r1 = os.path.join(HERE, f'.{label}.r1.fq')
    r2 = os.path.join(HERE, f'.{label}.r2.fq')
    with open(tpl, 'w') as fh:
        fh.write(f'>{label}\n{amplicon}\n')
    L = len(amplicon)
    # One "pair" per amplicon molecule: the fragment is the whole amplicon, so
    # read 1 is the whole amplicon in one orientation or the other (wgsim picks
    # the strand at random, like an unoriented merged read set). Read 2 is
    # discarded. No SNPs (-r 0) and no indels (-R 0, -X 0), substitutions only.
    cmd = [WGSIM, '-e', str(ERROR_RATE), '-d', str(L), '-s', '0', '-N', str(n),
           '-1', str(L), '-2', str(L), '-r', '0', '-R', '0', '-X', '0', '-S', str(seed), tpl, r1, r2]
    print(' '.join(os.path.basename(c) if c in (tpl, r1, r2) else c for c in cmd))
    subprocess.run(cmd, check=True, capture_output=True)
    with open(r1) as fh:
        lines = fh.read().splitlines()
    for i in range(0, len(lines), 4):
        reads.append(tuple(lines[i:i + 4]))
        truth.append((lines[i][1:].split()[0], latin))
    for p in (tpl, r1, r2):
        os.remove(p)

order = list(range(len(reads)))
random.Random(SHUFFLE_SEED).shuffle(order)
# mtime=0 keeps the gzip header byte-stable so reruns reproduce the file exactly.
with gzip.GzipFile(os.path.join(HERE, f'{BASENAME}.fastq.gz'), 'wb', mtime=0) as raw:
    for i in order:
        raw.write(('\n'.join(reads[i]) + '\n').encode())
with open(os.path.join(HERE, f'{BASENAME}.truth.tsv'), 'w') as fh:
    fh.write('read_name\tscientific_name\n')
    for i in order:
        fh.write(f'{truth[i][0]}\t{truth[i][1]}\n')

counts = {}
for _, latin in truth:
    counts[latin] = counts.get(latin, 0) + 1
print(f'wrote {len(reads)} simulated reads: ' + ', '.join(f'{k} {v}' for k, v in counts.items()))
