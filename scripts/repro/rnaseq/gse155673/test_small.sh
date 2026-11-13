#!/usr/bin/env bash
# Light test of the chain before the heavy steps: the first 100,000 spots of SRR12404157
# (cov_10) read from SRA with fastq-dump, a chromosome 19 reference cut from REPRO-10X's
# GRCh38-3.0.0 FASTA and GTF, solo.sh, compare.py and the substituted claims run, all in a
# throw-away folder. The numbers are meaningless (one chromosome, 0.04% of the reads); the
# test proves the read layout (28 nt R1, 91 nt R2), the code paths and the outputs.
# Usage: test_small.sh <data_root> <full_work_dir> <env_prefix> <test_dir>
set -euo pipefail
DATA=$1; FULL=$2; ENVP=$3; T=$4
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH="$ENVP/bin:$PATH"
REF=$DATA/work/tenx-controls/ref/GRCh38-3.0.0
RUN=SRR12404157; GSM=GSM4712899; N=${TEST_SPOTS:-100000}
mkdir -p "$T/work/ref" "$T/work/index" "$T/fq/$GSM" "$T/dump"
[ -s "$T/work/ref/genome.fa" ] || awk '/^>/ {keep = ($1 == ">19")} keep' "$REF/genome.fa" > "$T/work/ref/genome.fa"
[ -s "$T/work/ref/genes.gtf" ] || awk -F'\t' '$1 == "19"' "$REF/genes.gtf" > "$T/work/ref/genes.gtf"
[ -s "$T/work/index/SA" ] || STAR --runMode genomeGenerate --runThreadN 4 --genomeDir "$T/work/index" \
  --genomeFastaFiles "$T/work/ref/genome.fa" --sjdbGTFfile "$T/work/ref/genes.gtf" \
  --sjdbOverhang 100 --genomeSAindexNbases 11 --outFileNamePrefix "$T/work/index/" > /dev/null
if [ ! -s "$T/fq/$GSM/${RUN}_R2_cDNA.fastq.gz" ]; then
  fastq-dump -X "$N" --split-files -O "$T/dump" "$RUN"
  # Assign each read file by its length, as the staging worker's splitter does.
  for f in "$T/dump/${RUN}"_*.fastq; do
    len=$(awk 'NR == 2 {print length($0); exit}' "$f")
    case $len in
      28) gzip -c "$f" > "$T/fq/$GSM/${RUN}_R1_barcodeUMI.fastq.gz" ;;
      91) gzip -c "$f" > "$T/fq/$GSM/${RUN}_R2_cDNA.fastq.gz" ;;
      8) gzip -c "$f" > "$T/fq/$GSM/${RUN}_I1_index.fastq.gz" ;;
      *) echo "test: unexpected read length $len in $f"; exit 1 ;;
    esac
    echo "test: $(basename "$f") length $len, $(( $(wc -l < "$f") / 4 )) records"
  done
fi
head -1 "$HERE/runs.tsv" > "$T/runs.tsv"
awk -F'\t' -v r=$RUN '$1 == r' "$HERE/runs.tsv" >> "$T/runs.tsv"
ln -sfn "$FULL/deposited" "$T/work/deposited"
cp "$FULL/samples.tsv" "$T/work/samples.tsv"
WL=$DATA/work/tenx-controls/whitelist/3M-february-2018.txt
bash "$HERE/solo.sh" "$T/fq" "$T/work" "$T/runs.tsv" 4 - "$T/work/index" "$WL"
python3 -I "$HERE/compare.py" "$T/work" "$T/runs.tsv" "$T/work/samples.tsv"
python3 -I "$HERE/claims.py" "$T/work" "$T/work/samples.tsv" "$T/work/claims/substituted" \
  "$T/work/solo/$GSM/Solo.out/Gene/filtered" > "$T/claims_substituted.log"
grep -E "^cov10|^isg_pseudobulk" "$T/claims_substituted.log"
