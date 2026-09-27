#!/usr/bin/env python3
"""Build a small deduplicated 12S reference FASTA plus a MIDORI-style metadata
TSV from the five primate mitochondrial genomes in the sibling primate-mito
fixture, plus one shared-sequence record cut from the Japanese macaque genome.

Reads   ../primate-mito/primate-mito.fasta
        NC_025513.1.fasta            (Macaca fuscata mitochondrion, RefSeq)
Writes  primate-12s-dedup.fasta
        primate-12s-midori.tsv
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
MITO = os.path.join(HERE, os.pardir, 'primate-mito', 'primate-mito.fasta')
FUSCATA = os.path.join(HERE, 'NC_025513.1.fasta')


def read_fasta(path):
    seqs = {}
    name = None
    for line in open(path):
        line = line.strip()
        if line.startswith('>'):
            name = line[1:]
            seqs[name] = []
        elif name:
            seqs[name].append(line)
    return {k: ''.join(v).upper() for k, v in seqs.items()}


seqs = read_fasta(MITO)
fuscata = next(iter(read_fasta(FUSCATA).values()))

# Human MT-RNR1 (12S rRNA) is NC_012920.1:648-1601. Take a 12S slice that is
# short enough for a 250 bp read to contain it with flanking bases on both
# sides (the matcher's soft-clip requirement).
human = seqs['Human_NC_012920.1']
START, LEN = 900, 60          # inside MT-RNR1
probe = human[START:START + LEN]

# The MiFish-style approach: find the homologous slice in each other genome by
# anchoring on conserved flanks. Here we simply search each genome for the best
# ungapped match of the human probe's conserved 5' anchor, then take LEN bases.
anchor = human[START:START + 18]

# The reference FASTA header must read "Common name (Scientific name)". The
# metadata joiner parses the species out of that header
# (TwelveSReferenceMetadata.parseSpeciesLabel), and an underscored header
# leaves every metadata column empty.
TAXA = [
    ('Human_NC_012920.1',             'Homo sapiens',        'Human',              'Mammal', '9606'),
    ('Chimp_NC_001643.1',             'Pan troglodytes',     'Chimpanzee',         'Mammal', '9598'),
    ('Gorilla_NC_011120.1',           'Gorilla gorilla',     'Western gorilla',    'Mammal', '9593'),
    ('RhesusMacaque_NC_005943.1',     'Macaca mulatta',      'Rhesus macaque',     'Mammal', '9544'),
    ('CynomolgusMacaque_NC_012670.1', 'Macaca fascicularis', 'Cynomolgus macaque', 'Mammal', '9541'),
]

# The sixth record is a second rhesus target whose 60 bases are identical in
# the Japanese macaque (Macaca fuscata, NC_025513.1) and absent from every
# other genome here. It is written once, under the rhesus name, with the
# shared species in the header's also_matches field, which is how a
# deduplicated reference records that one sequence belongs to two species.
# The matcher reads that field (TwelveSReferenceIndex.parseHeader) and the
# viewport shows it in the Alternates column.
FUSCATA_TAXON = ('Macaca fuscata', 'Japanese macaque', 'Mammal', '9542')


def best_slice(genome):
    """Return the LEN-base window whose first 18 bases best match the anchor."""
    best, best_score = None, -1
    for i in range(len(genome) - LEN):
        w = genome[i:i + 18]
        score = sum(1 for a, b in zip(w, anchor) if a == b)
        if score > best_score:
            best_score, best = score, genome[i:i + LEN]
    return best, best_score


records = []
meta = []
seen = {}
for key, latin, common, group, taxid in TAXA:
    s, score = best_slice(seqs[key])
    print(f'{latin}: anchor identity {score}/18')
    if s in seen:
        print(f'  identical to {seen[s]}, collapsed')
        continue
    seen[s] = latin
    records.append((f'{common} ({latin})', s))
    meta.append((
        latin.replace(' ', '_'), common, latin, group, taxid, 'NCBI',
        f'Chordata;Mammalia;Primates;{latin}',
    ))


def rc(s):
    return s.translate(str.maketrans('ACGTN', 'TGCAN'))[::-1]


def find_primer(genome, primer):
    """Best ungapped placement of a primer (0-based start, mismatches)."""
    best, best_mm = None, 99
    for i in range(len(genome) - len(primer) + 1):
        mm = sum(1 for a, b in zip(genome[i:i + len(primer)], primer) if a != b)
        if mm < best_mm:
            best_mm, best = mm, i
    return best, best_mm


# Shared rhesus/Japanese macaque window: the first LEN-base window inside the
# rhesus MiFish-U amplicon (primer to primer) that occurs verbatim in the
# M. fuscata genome and in no other genome of the reference.
rhesus = seqs['RhesusMacaque_NC_005943.1']
MIFISH_U_F = 'GTCGGTAAAACTCGTGCCAGC'
MIFISH_U_R = 'CATAGTGGGGTATCTAATCCCAGTTTG'
f_start, _ = find_primer(rhesus, MIFISH_U_F)
r_start, _ = find_primer(rhesus, rc(MIFISH_U_R))
insert_start, insert_end = f_start + len(MIFISH_U_F), r_start
others = [g for k, g in seqs.items() if k != 'RhesusMacaque_NC_005943.1']
shared = None
for i in range(insert_start, insert_end - LEN + 1):
    w = rhesus[i:i + LEN]
    if w in fuscata and not any(w in g for g in others):
        shared = (i, w)
        break
if shared is None:
    raise SystemExit('no rhesus window shared with M. fuscata and unique otherwise')
print(f'Macaca mulatta / Macaca fuscata shared window at NC_005943.1:{shared[0] + 1}-{shared[0] + LEN} ({LEN} bases)')
records.append((
    'Rhesus macaque (Macaca mulatta)|also_matches=Japanese macaque (Macaca fuscata)',
    shared[1],
))
latin, common, group, taxid = FUSCATA_TAXON
meta.append((
    latin.replace(' ', '_'), common, latin, group, taxid, 'NCBI',
    f'Chordata;Mammalia;Primates;{latin}',
))

with open(os.path.join(HERE, 'primate-12s-dedup.fasta'), 'w') as fh:
    for header, s in records:
        fh.write(f'>{header}\n{s}\n')

with open(os.path.join(HERE, 'primate-12s-midori.tsv'), 'w') as fh:
    fh.write('seq_id\tcommon_name\tlatin_name\tgroup\ttaxid\tname_source\ttaxonomy\n')
    for row in meta:
        fh.write('\t'.join(row) + '\n')

print(f'wrote {len(records)} reference records of {LEN} bases')
