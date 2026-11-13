#!/usr/bin/env bash
# C9 end to end: GSE163196 (PBL) and GSE163195 (CSF), the UMI route.
# Usage: run.sh <data_dir> <work_dir> <env_dir> [star_index]
#   data_dir   holds studies/GSE163196, studies/GSE163195, refs/human/ensembl-100 and locks/
#   work_dir   receives every derived file
#   env_dir    the conda environment (umi_tools, STAR, featureCounts, samtools, pigz, Rscript)
#   star_index an existing STAR index of the Ensembl 100 GRCh38 primary assembly; without it one
#              is built (sparse SA 2, sjdbOverhang 100) under the heavy lock
# Environment: LOCKS (default <data_dir>/locks, "-" for none), PAR (runs at once, default 2),
#              ALL_RUNS=1 to also align the twelve 2020 runs whose reads the 2024 runs repeat,
#              STAGES (default "layout seqhash ref runs matrix compare de claims").
set -euo pipefail
DATA=$(cd "$1" && pwd); WORK=$2; ENV=$(cd "$3" && pwd); IDX=${4:-}
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
LOCKS=${LOCKS:-$DATA/locks}
PAR=${PAR:-2}
STAGES=${STAGES:-"layout seqhash ref runs matrix compare de claims"}
B=$ENV/bin
S=$DATA/studies
mkdir -p "$WORK/logs" "$WORK/ref" "$WORK/runs" "$WORK/tmp"
has() { case " $STAGES " in *" $1 "*) return 0;; *) return 1;; esac; }
fq() { local st; st=$(awk -F'\t' -v r="$1" '$1==r{print $2}' "$HERE/samples.tsv"); echo "$S/$st/fastq/$1_$2.fastq.gz"; }

# Runs to align: every CSF run, every 2024 PBL run, and the 2020 PBL run with no 2024 twin.
# The 16 runs of the paper's groups I to III come first.
RUNS=$(awk -F'\t' -v all="${ALL_RUNS:-0}" 'NR>1 && (all==1 || $2=="GSE163195" || $1 ~ /^SRR28/ || $9=="NA"){print ($7=="NA"), $1}' "$HERE/samples.tsv" | sort -k1,1n -s | cut -d' ' -f2)

if has layout; then   # claim C9-2: read structure in the first 1,000 pairs of every run
  printf 'run\tpairs\tnames_equal\tstart_ATCAATC\tle1mm\tdistinct_umi\tTrich_24_33\tr1_med\tr2_med\ttop7\n' > "$WORK/layout.tsv"
  for r in $(awk -F'\t' 'NR>1{print $1}' "$HERE/samples.tsv"); do
    nice -n 15 "$B/python" -I "$HERE/layout.py" "$r" "$(fq "$r" 1)" "$(fq "$r" 2)" 1000 >> "$WORK/layout.tsv"
  done
fi

if has seqhash; then  # do the 2024 runs hold the same read pairs as the 2020 runs with equal counts?
  # pairhash.py is order free. seqhash.sh (order dependent) showed the two uploads list pairs in another order.
  : > "$WORK/pairhash.tsv"
  for r in $(awk -F'\t' 'NR>1 && $9!="NA"{print $1}' "$HERE/samples.tsv"); do
    nice -n 15 "$B/python" -I "$HERE/pairhash.py" "$r" "$(fq "$r" 1)" "$(fq "$r" 2)" "$B/pigz" >> "$WORK/pairhash.tsv"
  done
fi

GTF=$WORK/ref/genes.gtf
if has ref; then
  [ -s "$GTF" ] || "$B/pigz" -dc "$DATA/refs/human/ensembl-100/Homo_sapiens.GRCh38.100.gtf.gz" > "$GTF"
  mkdir -p "$WORK/deposited/pbl" "$WORK/deposited/csf"
  tar -xf "$S/GSE163196/geo/GSE163196_RAW.tar" -C "$WORK/deposited/pbl"
  tar -xf "$S/GSE163195/geo/GSE163195_RAW.tar" -C "$WORK/deposited/csf"
  if [ -z "$IDX" ]; then
    IDX=$WORK/star_index
    if [ ! -e "$IDX/.complete" ]; then
      mkdir -p "$IDX"
      [ -s "$WORK/ref/genome.fa" ] || "$B/pigz" -dc "$DATA/refs/human/ensembl-100/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz" > "$WORK/ref/genome.fa"
      "$HERE/heavy.sh" "$LOCKS" "REPRO-C9 index" 600 nice -n 15 "$B/STAR" --runMode genomeGenerate --runThreadN 8 \
        --genomeDir "$IDX" --genomeFastaFiles "$WORK/ref/genome.fa" --sjdbGTFfile "$GTF" --sjdbOverhang 100 \
        --genomeSAsparseD 2 --limitGenomeGenerateRAM 32000000000 --outFileNamePrefix "$IDX/" > "$WORK/logs/index.log" 2>&1
      touch "$IDX/.complete"
    fi
  fi
fi
IDX=${IDX:-$WORK/star_index}

if has runs; then
  # one line of eight arguments a run (no path here holds a space)
  # One line of eight arguments a run (no path here holds a space). The last argument is the
  # locks folder, and "-" tells sample.sh that its caller already holds the heavy lock.
  for r in $RUNS; do echo "$r $(fq "$r" 1) $(fq "$r" 2) $WORK/runs $ENV $IDX $GTF -"; done > "$WORK/logs/jobs.txt"
  # Three lanes, so that extraction never waits behind the heavy lock: extract (PAR at once),
  # STAR (one run at a time, every run under one hold of the lock, so the genome loads stay
  # back to back) and the light counting steps (POST_PAR at once).
  STEPS=extract xargs -P "$PAR" -L 1 "$HERE/sample.sh" < "$WORK/logs/jobs.txt" >> "$WORK/logs/runs.log" 2>&1 &
  STEPS=star "$HERE/heavy.sh" "$LOCKS" "REPRO-C9 STAR batch" 900 xargs -P 1 -L 1 "$HERE/sample.sh" \
    < "$WORK/logs/jobs.txt" >> "$WORK/logs/runs.log" 2>&1 &
  STEPS="reads count dedup" xargs -P "${POST_PAR:-1}" -L 1 "$HERE/sample.sh" < "$WORK/logs/jobs.txt" >> "$WORK/logs/runs.log" 2>&1 &
  wait
fi

if has matrix; then   # gene by sample tables of the three counts: reads (R), paper route (P), plan route (L)
  nice -n 15 "$B/python" -I "$HERE/matrix.py" "$HERE/samples.tsv" "$WORK/runs" "$GTF" "$WORK/matrix" "$WORK/deposited"
fi

if has compare; then  # claims C9-1, C9-1b, C9-4 and the UMI against read figures
  mkdir -p "$WORK/compare"
  nice -n 15 "$B/python" -I "$HERE/compare.py" "$HERE/samples.tsv" "$WORK/matrix" "$WORK/deposited" "$WORK/compare" > "$WORK/compare/summary.txt"
fi

if has de; then       # claim C9-3: DESeq2 PBL against CSF in groups I to III, on the deposit, then on ours
  mkdir -p "$WORK/de"
  for src in deposited ours_P ours_L; do
    nice -n 15 "$B/Rscript" "$HERE/de.R" "$HERE/samples.tsv" "$WORK/matrix/$src.tsv" "$WORK/de/$src" > "$WORK/logs/de_$src.log" 2>&1
  done
  nice -n 15 "$B/python" -I "$HERE/de_compare.py" "$WORK/de" "$WORK/matrix/genes.tsv" > "$WORK/de/summary.txt"
fi

if has claims; then
  nice -n 15 "$B/python" -I "$HERE/claims.py" "$WORK" > "$HERE/claims.tsv"
fi
