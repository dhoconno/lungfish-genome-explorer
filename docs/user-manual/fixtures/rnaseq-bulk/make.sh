#!/bin/bash
# make.sh <fastq folder> <work folder> [pairs]
#
# Rebuilds salmon-seqc-ercc/ of this fixture. It cuts the first <pairs> read pairs (default 200000, and the shipped
# folders used 1000000) of six SEQC runs of GSE47774 (samples A and B, libraries 1 to 3), counts each cut against the
# 92 ERCC sequences with salmon 2.11.0 and keeps the small files of each salmon folder.
#
# <fastq folder> holds <run>_1.fastq.gz and <run>_2.fastq.gz of the six runs. ENA serves them under
# ftp.sra.ebi.ac.uk/vol1/fastq/SRR896/<run>/. The shipped folders were cut from ENA's files for SRR896679, SRR896743,
# SRR896759 and SRR896775 and from fasterq-dump conversions of the NCBI SRA files for SRR896663 and SRR896695, whose
# sequence and quality lines equal ENA's (their read names end in " length=100" and not in "/1" or "/2"). Only the
# first <pairs> pairs of each file are read, so a partial download that holds them is enough. <work folder> must be
# new or empty. salmon 2.11.0 must be on PATH.
set -eu

FASTQ="$1"
WORK="$2"
PAIRS="${3:-200000}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FA="$HERE/salmon-probe-c1/ERCC92.fa"
RUNS="SRR896663 SRR896679 SRR896695 SRR896743 SRR896759 SRR896775"

[ "$(salmon --version)" = "salmon 2.11.0" ] || { echo "make.sh: salmon 2.11.0 is required, found: $(salmon --version)" >&2; exit 2; }
[ -z "$(ls -A "$WORK" 2>/dev/null)" ] || { echo "make.sh: $WORK is not empty" >&2; exit 2; }
mkdir -p "$WORK"
cd "$WORK"
mkdir reads quant salmon-seqc-ercc

# The index of the 92 ERCC sequences. No decoys, since the genome of this set is the transcripts themselves.
salmon index -t "$FA" -i ercc92_index -k 31 -p 4 > index.log 2>&1

: > salmon-seqc-ercc/cut-reads.sha256
for run in $RUNS; do
  for mate in 1 2; do
    gzip -dc "$FASTQ/${run}_${mate}.fastq.gz" | head -n $((PAIRS * 4)) | gzip -n -6 > "reads/${run}_${mate}.fastq.gz" || true
  done
  # Both mates must name the same reads in the same order.
  bad=$(paste -d' ' <(gzip -dc "reads/${run}_1.fastq.gz" | awk 'NR%4==1 {print $1}') \
                    <(gzip -dc "reads/${run}_2.fastq.gz" | awk 'NR%4==1 {print $1}') | awk '$1!=$2 {n++} END {print n+0}')
  [ "$bad" = "0" ] || { echo "make.sh: mates of $run name different reads ($bad)" >&2; exit 3; }
  for mate in 1 2; do
    echo "$(gzip -dc "reads/${run}_${mate}.fastq.gz" | shasum -a 256 | cut -d' ' -f1)  ${run}_${mate}.fastq (uncompressed bytes of the cut, $(gzip -dc "reads/${run}_${mate}.fastq.gz" | awk 'NR%4==1' | wc -l | tr -d ' ') reads)" >> salmon-seqc-ercc/cut-reads.sha256
  done
  salmon quant -i ercc92_index -l A -1 "reads/${run}_1.fastq.gz" -2 "reads/${run}_2.fastq.gz" -p 1 -o "quant/$run" > "quant/$run.log" 2>&1
  mkdir -p "salmon-seqc-ercc/$run/aux_info"
  cp "quant/$run/cmd_info.json" "quant/$run/lib_format_counts.json" "quant/$run/quant.sf" "salmon-seqc-ercc/$run/"
  cp "quant/$run/aux_info/meta_info.json" "salmon-seqc-ercc/$run/aux_info/"
  echo "$run done"
done
