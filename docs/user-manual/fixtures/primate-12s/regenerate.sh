#!/usr/bin/env bash
# Rebuild the constructed 12S fixture from the two sibling fixtures it is cut
# from: primate-mito (the five mitochondrial genomes the reference targets come
# out of) and human-mito (the HG002 chrM reads the amplicon read set is drawn
# from), plus the committed Japanese macaque genome NC_025513.1.fasta. Nothing
# is fetched from the network.
#
#   ../primate-mito/primate-mito.fasta      -> primate-12s-dedup.fasta
#   NC_025513.1.fasta                          primate-12s-midori.tsv
#                                              primate-12s-targets.tsv
#   ../human-mito/HG002.chrM_R1.fastq.gz    -> HG002-12S-amplicon.fastq.gz
#                                              HG002-12S-oriented.fastq
#   ../primate-mito/primate-mito.fasta      -> SIMULATED-12S-mixture.amplicons.fasta
#                                              SIMULATED-12S-mixture.fastq.gz
#                                              SIMULATED-12S-mixture.truth.tsv
#                                              SIMULATED-12S-mixture-oriented.fastq.gz
set -euo pipefail
cd "$(dirname "$0")"
CLI=${LUNGFISH_CLI:-/Users/dho/Documents/lungfish-genome-explorer/.build/debug/lungfish-cli}
export WGSIM=${WGSIM:-wgsim}

# 1. Cut the 60-base 12S reference targets and the MIDORI-style metadata table
#    out of the five primate mitochondrial genomes, plus the shared
#    rhesus/Japanese macaque record.
python3 build_ref.py

# 2. Select the HG002 chrM reads that overlap the human 12S locus, so the read
#    set behaves like a 12S amplicon library rather than a whole-mitochondrion
#    shotgun run.
python3 make_amplicon.py

# 3. Join the reference FASTA to the metadata table. The join is on the species
#    name parsed out of the FASTA header, which is why build_ref.py writes
#    headers in the "Common name (Scientific name)" form.
"$CLI" fastq 12s-reference-metadata \
  --dedup-fasta primate-12s-dedup.fasta \
  --midori-metadata primate-12s-midori.tsv \
  --output primate-12s-targets.tsv --force

# 4. Orient the amplicon reads against the reference. The 12S matcher has no
#    reverse-complement pass, so reverse-strand reads go unmatched until this
#    step flips them. --compress is deliberately omitted: the CLI writes plain
#    text regardless, so asking for a .gz name only produces a mislabelled file.
"$CLI" fastq orient HG002-12S-amplicon.fastq.gz \
  --reference primate-12s-dedup.fasta \
  --output HG002-12S-oriented.fastq --force

# 5. SIMULATED three-species mixture (human 70 %, rhesus 25 %, cynomolgus 5 %)
#    from the MiFish-U amplicon of each genome, with wgsim at fixed seeds, then
#    oriented the same way as the HG002 reads.
#    orient writes plain text whatever the output name, so the oriented file
#    is gzipped afterwards (zeroed timestamp) to stay under the repository's
#    500 KB limit for files under docs/.
python3 simulate_mixture.py
"$CLI" fastq orient SIMULATED-12S-mixture.fastq.gz \
  --reference primate-12s-dedup.fasta \
  --output SIMULATED-12S-mixture-oriented.fastq --force
python3 - <<'PY'
import gzip
with open('SIMULATED-12S-mixture-oriented.fastq', 'rb') as src, \
        gzip.GzipFile('SIMULATED-12S-mixture-oriented.fastq.gz', 'wb', mtime=0) as dst:
    dst.write(src.read())
PY
rm -f SIMULATED-12S-mixture-oriented.fastq

echo "reference targets: $(grep -c '^>' primate-12s-dedup.fasta)"
echo "amplicon reads:    $(( $(gzcat HG002-12S-amplicon.fastq.gz | wc -l) / 4 ))"
echo "oriented reads:    $(( $(wc -l < HG002-12S-oriented.fastq) / 4 ))"
echo "simulated reads:   $(( $(gzcat SIMULATED-12S-mixture.fastq.gz | wc -l) / 4 ))"
echo "simulated oriented: $(( $(gzcat SIMULATED-12S-mixture-oriented.fastq.gz | wc -l) / 4 ))"
