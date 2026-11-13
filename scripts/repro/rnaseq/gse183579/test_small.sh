#!/usr/bin/env bash
# Light test of the chain before the heavy steps: a reference of chromosome 19, MT and
# NC_045512.2, the first 100,000 spots of one run of each of two libraries, solo.sh, the
# viral slice and compare.py, all in a throw-away work folder.
# Usage: test_small.sh <data_root> <full_work_dir> <env_prefix> <test_dir>
set -euo pipefail
DATA=$1; FULL=$2; ENVP=$3; T=$4
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH="$ENVP/bin:$PATH"
mkdir -p "$T/work/ref" "$T/work/whitelist" "$T/data/studies/GSE183579"
[ -s "$FULL/ref/genome.fa.fai" ] || samtools faidx "$FULL/ref/genome.fa"
samtools faidx "$FULL/ref/genome.fa" 19 MT NC_045512.2 > "$T/work/ref/genome.fa"
awk -F'\t' '$1 == "19" || $1 == "MT" || $1 == "NC_045512.2"' "$FULL/ref/genes.gtf" > "$T/work/ref/genes.gtf"
ln -sf "$FULL/whitelist/3M-february-2018.txt" "$T/work/whitelist/3M-february-2018.txt"
ln -sfn "$FULL/deposited" "$T/work/deposited"
cp "$FULL/samples.tsv" "$T/work/samples.tsv"
cp "$FULL/ref/genes.tsv" "$T/work/ref/genes.tsv"
mkdir -p "$T/work/index"
[ -s "$T/work/index/SA" ] || STAR --runMode genomeGenerate --runThreadN 4 --genomeDir "$T/work/index" \
  --genomeFastaFiles "$T/work/ref/genome.fa" --sjdbGTFfile "$T/work/ref/genes.gtf" \
  --sjdbOverhang 100 --genomeSAindexNbases 11 --outFileNamePrefix "$T/work/index/" > /dev/null
head -1 "$HERE/runs.tsv" > "$T/runs.tsv"
for g in GSM5560892 GSM5560900; do
  r=$(awk -F'\t' -v g=$g '$2 == g {print $1; exit}' "$HERE/runs.tsv")
  awk -F'\t' -v r=$r '$1 == r' "$HERE/runs.tsv" >> "$T/runs.tsv"
  mkdir -p "$T/data/studies/GSE183579/fastq/$g"
  for role in R1_barcodeUMI R2_cDNA; do
    gzip -cd "$DATA/studies/GSE183579/fastq/$g/${r}_$role.fastq.gz" | head -400000 | gzip -1 \
      > "$T/data/studies/GSE183579/fastq/$g/${r}_$role.fastq.gz" || true
  done
done
bash "$HERE/solo.sh" "$T/data" "$T/work" "$T/runs.tsv" 4 -
bash "$HERE/run.sh" "$T/data" "$T/work" "$ENVP" slice
