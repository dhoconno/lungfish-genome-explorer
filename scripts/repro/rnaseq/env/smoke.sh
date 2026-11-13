#!/usr/bin/env bash
# Smoke test for the RNA-seq reproduction environment.
#
# Usage: smoke.sh ENV_PREFIX FIXTURE_DIR [WORK_DIR]
#
#   ENV_PREFIX   the conda prefix, for example /Volumes/lge_scratch/lge/rnaseq/env
#   FIXTURE_DIR  the HBR/UHR chr22 folder with reads/ and ref/ inside
#   WORK_DIR     optional, defaults to a new folder in a smoke/ folder beside ENV_PREFIX
#
# It prints the version of every tool, then runs one tiny real job for STAR (index and align),
# salmon (index and quant), featureCounts, umi_tools and an R script that loads DESeq2, edgeR,
# limma, tximport, apeglm, pROC and rpart and fits DESeq2 on a toy matrix, with apeglm shrinkage,
# a ROC curve and a small tree. The helpers fastp, gffread, samtools, seqkit and pigz run once on
# the way.
#
# The third environment holds the R packages with sva (env-r-sva, found beside ENV_PREFIX). sva
# pins edgeR 4.8.x and limma 3.66.x, so it cannot live in ENV_PREFIX. There the script runs a toy
# matrix through ComBat_seq, svaseq, DESeq2 (on the raw and on the adjusted counts), apeglm, pROC,
# rpart and edgeR with limma voom, and requires every one of those R packages to come from that
# environment's own library.
#
# The second environment holds STAR 2.7.3a (env-star273a, osx-64 packages that run under
# Rosetta 2). It is found beside ENV_PREFIX. The script checks that it prints 2.7.3a, builds the
# same chromosome 22 index, aligns the same pair with --quantMode GeneCounts and compares the
# ReadsPerGene table with the one that STAR in ENV_PREFIX wrote.
#
# Environment variables
#   SMOKE_THREADS   threads for STAR and salmon (default 4)
#   SMOKE_KEEP=1    keep the work folder after a pass (it is always kept after a failure)
#   SMOKE_STAR273A  prefix of the STAR 2.7.3a environment (default env-star273a beside ENV_PREFIX),
#                   or "skip" to leave the STAR 2.7.3a steps out
#   SMOKE_R_SVA     prefix of the R environment with sva (default env-r-sva beside ENV_PREFIX),
#                   or "skip" to leave the sva steps out
#
# Exit status is 0 when every step passed, 1 when any step failed, 2 for a usage error.
# The script targets bash 3.2, so it works with the system bash on macOS.

set -u

if [ "$#" -lt 2 ]; then
  echo "usage: $0 ENV_PREFIX FIXTURE_DIR [WORK_DIR]" >&2
  exit 2
fi

ENV_PREFIX=$(cd "$1" 2>/dev/null && pwd) || { echo "no such environment: $1" >&2; exit 2; }
FIXTURE_DIR=$(cd "$2" 2>/dev/null && pwd) || { echo "no such fixture folder: $2" >&2; exit 2; }
THREADS="${SMOKE_THREADS:-4}"
STAR273A_PREFIX="${SMOKE_STAR273A:-$(dirname "$ENV_PREFIX")/env-star273a}"
R_SVA_PREFIX="${SMOKE_R_SVA:-$(dirname "$ENV_PREFIX")/env-r-sva}"

READS="$FIXTURE_DIR/reads"
REF="$FIXTURE_DIR/ref"
FASTA="$REF/chr22_with_ERCC92.fa"
GTF="$REF/chr22_with_ERCC92.gtf"
R1="$READS/HBR_Rep1_ERCC-Mix2_Build37-ErccTranscripts-chr22.read1.fastq.gz"
R2="$READS/HBR_Rep1_ERCC-Mix2_Build37-ErccTranscripts-chr22.read2.fastq.gz"
for f in "$FASTA" "$GTF" "$R1" "$R2"; do
  [ -s "$f" ] || { echo "missing fixture file: $f" >&2; exit 2; }
done
[ -x "$ENV_PREFIX/bin/STAR" ] || { echo "STAR not found in $ENV_PREFIX/bin" >&2; exit 2; }
if [ "$STAR273A_PREFIX" != "skip" ]; then
  [ -x "$STAR273A_PREFIX/bin/STAR" ] || { echo "STAR 2.7.3a not found in $STAR273A_PREFIX/bin (set SMOKE_STAR273A=skip to leave it out)" >&2; exit 2; }
  STAR273A_PREFIX=$(cd "$STAR273A_PREFIX" && pwd)
fi
if [ "$R_SVA_PREFIX" != "skip" ]; then
  [ -x "$R_SVA_PREFIX/bin/Rscript" ] || { echo "Rscript not found in $R_SVA_PREFIX/bin (set SMOKE_R_SVA=skip to leave the sva steps out)" >&2; exit 2; }
  R_SVA_PREFIX=$(cd "$R_SVA_PREFIX" && pwd)
fi

if [ "$#" -ge 3 ]; then
  WORK="$3"
  mkdir -p "$WORK" || exit 2
else
  mkdir -p "$(dirname "$ENV_PREFIX")/smoke" || exit 2
  WORK=$(mktemp -d "$(dirname "$ENV_PREFIX")/smoke/run.XXXXXX") || exit 2
fi
WORK=$(cd "$WORK" && pwd)
LOGS="$WORK/logs"
mkdir -p "$LOGS" "$WORK/scripts" "$WORK/ref"

# The fixture folder stays read-only. Tools that write an index beside their input (gffread) get symlinks.
ln -sf "$FASTA" "$WORK/ref/genome.fa"
ln -sf "$GTF" "$WORK/ref/annotation.gtf"
FASTA="$WORK/ref/genome.fa"
GTF="$WORK/ref/annotation.gtf"

# Tools run from the environment bin folder. Caches go to the work folder, not to the home folder.
export PATH="$ENV_PREFIX/bin:$PATH"
export CONDA_PREFIX="$ENV_PREFIX"
export MPLCONFIGDIR="$WORK/cache/mpl"
export NUMBA_CACHE_DIR="$WORK/cache/numba"
export XDG_CACHE_HOME="$WORK/cache/xdg"
export ALEVIN_FRY_HOME="$WORK/alevin_fry_home"
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$MPLCONFIGDIR" "$NUMBA_CACHE_DIR" "$XDG_CACHE_HOME" "$ALEVIN_FRY_HOME"

PASSED=0
FAILED=0
SUMMARY="$WORK/summary.txt"
: > "$SUMMARY"

note() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }

# run_step NAME FUNCTION: runs FUNCTION with its output in logs/NAME.log and counts the result.
run_step() {
  local name="$1" fn="$2" t0 t1 rc
  t0=$(date +%s)
  "$fn" > "$LOGS/$name.log" 2>&1
  rc=$?
  t1=$(date +%s)
  if [ "$rc" -eq 0 ]; then
    PASSED=$((PASSED + 1))
    note "$(printf 'PASS  %-24s %4ss' "$name" $((t1 - t0)))"
  else
    FAILED=$((FAILED + 1))
    note "$(printf 'FAIL  %-24s %4ss  rc=%s  log=%s' "$name" $((t1 - t0)) "$rc" "$LOGS/$name.log")"
    tail -n 8 "$LOGS/$name.log" | sed 's/^/        /' | tee -a "$SUMMARY"
  fi
}

# ver LABEL COMMAND...: records the first line a version command prints.
ver() {
  local label="$1" out rc line
  shift
  out=$("$@" 2>&1); rc=$?
  line=$(printf '%s\n' "$out" | grep -E '[0-9]+\.[0-9]+' | head -n 1)
  [ -n "$line" ] || line=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -n 1)
  if [ -n "$line" ] && { [ "$rc" -eq 0 ] || { printf '%s' "$line" | grep -Eq '[0-9]+\.[0-9]+' && ! printf '%s' "$out" | grep -Eqi 'library not loaded|dyld|killed|abort|no such file'; }; }; then
    PASSED=$((PASSED + 1))
    note "$(printf 'PASS  version %-16s %s' "$label" "$line")"
  else
    FAILED=$((FAILED + 1))
    note "$(printf 'FAIL  version %-16s rc=%s %s' "$label" "$rc" "$line")"
  fi
}

# ver_exact LABEL WANT COMMAND...: passes when the first line the command prints equals WANT.
ver_exact() {
  local label="$1" want="$2" out rc line
  shift 2
  out=$("$@" 2>&1); rc=$?
  line=$(printf '%s\n' "$out" | head -n 1)
  if [ "$rc" -eq 0 ] && [ "$line" = "$want" ]; then
    PASSED=$((PASSED + 1))
    note "$(printf 'PASS  version %-16s %s' "$label" "$line")"
  else
    FAILED=$((FAILED + 1))
    note "$(printf 'FAIL  version %-16s rc=%s got "%s", want "%s"' "$label" "$rc" "$line" "$want")"
  fi
}

note "smoke test started $(date '+%F %T') on $(uname -sm)"
note "environment $ENV_PREFIX"
note "STAR 2.7.3a $STAR273A_PREFIX"
note "R with sva   $R_SVA_PREFIX"
note "fixtures    $FIXTURE_DIR"
note "work folder $WORK"
note "threads     $THREADS"
note ""

note "== versions =="
ver STAR STAR --version
if [ "$STAR273A_PREFIX" != "skip" ]; then
  ver_exact STAR-2.7.3a 2.7.3a "$STAR273A_PREFIX/bin/STAR" --version
fi
ver salmon salmon --version
ver featureCounts featureCounts -v
ver htseq-count htseq-count --version
ver prefetch prefetch --version
ver fasterq-dump fasterq-dump --version
ver umi_tools umi_tools --version
ver samtools samtools --version
ver fastp fastp --version
ver gffread gffread --version
ver multiqc multiqc --version
ver simpleaf simpleaf --version
ver alevin-fry alevin-fry --version
ver piscem piscem --version
ver kallisto kallisto version
ver seqkit seqkit version
ver pigz pigz --version
ver python python -I --version
ver Rscript Rscript --version
if [ "$R_SVA_PREFIX" != "skip" ]; then
  ver Rscript-with-sva "$R_SVA_PREFIX/bin/Rscript" --version
fi

step_python_packages() (
  set -e
  python -I - <<'PY'
from importlib.metadata import version
import numpy, pandas, scipy, anndata, scanpy, yaml, HTSeq
for dist in ("numpy", "pandas", "scipy", "anndata", "scanpy", "PyYAML", "HTSeq"):
    print("%-8s %s" % (dist, version(dist)))
import numpy as np
import anndata as ad
import scanpy as sc
rng = np.random.default_rng(1)
adata = ad.AnnData(rng.poisson(2.0, size=(60, 40)).astype("float32"))
sc.pp.normalize_total(adata)
sc.pp.log1p(adata)
sc.pp.pca(adata, n_comps=5)
assert adata.obsm["X_pca"].shape == (60, 5)
print("scanpy normalize, log1p and pca ran on a toy matrix")
PY
)
run_step python-packages step_python_packages

step_r_versions() (
  set -e
  Rscript --vanilla -e '
    pk <- c("DESeq2", "edgeR", "limma", "tximport", "tximeta", "data.table", "jsonlite", "rpart", "apeglm", "pROC")
    for (p in pk) cat(sprintf("%-11s %s\n", p, as.character(packageVersion(p))))
    cat(R.version.string, "\n")
  '
)
run_step r-package-versions step_r_versions

note ""
note "== architecture of key binaries (information only) =="
for b in STAR salmon featureCounts samtools fastp kallisto seqkit alevin-fry simpleaf piscem python R; do
  p=$(command -v "$b" 2>/dev/null || true)
  if [ -n "$p" ] && [ "${p#"$ENV_PREFIX"/}" != "$p" ]; then
    note "$(printf '  %-12s %s' "$b" "$(file -b "$p" | sed 's/^.*\(Mach-O [^,]*\).*$/\1/' | head -n 1)")"
  fi
done
if [ "$STAR273A_PREFIX" != "skip" ]; then
  note "$(printf '  %-12s %s' "STAR 2.7.3a" "$(file -b "$STAR273A_PREFIX/bin/STAR" | sed 's/^.*\(Mach-O [^,]*\).*$/\1/' | head -n 1)")"
fi
note ""

note "== tiny real runs =="

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

# The four files the runs read must match the sums recorded when the fixtures were downloaded.
step_fixture_sums() (
  set -e
  while read -r want file; do
    got=$(sha256_of "$file")
    echo "$got  $file"
    test "$got" = "$want"
  done <<EOF
98acde4a57edaaba443206938ca1ebf8cf35bd2ea60548cccedf366ce3346296 $FASTA
f5ea9899f975a1bc2381994d1c429067e5b2ea1d73e5bcfabbb90bd81e49b5ff $GTF
db87dc303bf4d9389be5d665d5998f202b70582ed7904a66286365b0cf00fda3 $R1
076216029151099d96fe5e2bcc12d8c6528d4443ad1dfb35ec96cbeace4fa1ec $R2
EOF
)
run_step fixture-sha256 step_fixture_sums

step_seqkit_pigz() (
  set -e
  mkdir -p "$WORK/reads"
  seqkit stats "$R1" "$R2"
  seqkit head -n 20000 "$R1" -o "$WORK/reads/sub1.fastq.gz"
  seqkit head -n 20000 "$R2" -o "$WORK/reads/sub2.fastq.gz"
  gzip -cd "$WORK/reads/sub1.fastq.gz" | pigz -p 2 -c > "$WORK/reads/sub1.pigz.fastq.gz"
  gzip -t "$WORK/reads/sub1.pigz.fastq.gz"
  test "$(seqkit stats -T "$WORK/reads/sub1.pigz.fastq.gz" | awk 'NR==2 {print $4}')" = "20000"
)
run_step seqkit-pigz step_seqkit_pigz

step_fastp() (
  set -e
  mkdir -p "$WORK/fastp"
  fastp -i "$WORK/reads/sub1.fastq.gz" -I "$WORK/reads/sub2.fastq.gz" \
    -o "$WORK/fastp/out1.fastq.gz" -O "$WORK/fastp/out2.fastq.gz" \
    -j "$WORK/fastp/fastp.json" -h "$WORK/fastp/fastp.html" -w 2
  grep -q '"total_reads"' "$WORK/fastp/fastp.json"
)
run_step fastp step_fastp

step_gffread() (
  set -e
  mkdir -p "$WORK/ref"
  gffread -w "$WORK/ref/transcripts.fa" -g "$FASTA" "$GTF"
  n=$(grep -c '^>' "$WORK/ref/transcripts.fa")
  echo "transcripts written: $n"
  test "$n" -gt 500
)
run_step gffread step_gffread

step_star_index() (
  set -e
  mkdir -p "$WORK/star/index"
  STAR --runMode genomeGenerate --runThreadN "$THREADS" \
    --genomeDir "$WORK/star/index" --genomeFastaFiles "$FASTA" \
    --sjdbGTFfile "$GTF" --sjdbOverhang 100 --genomeSAindexNbases 11 \
    --outFileNamePrefix "$WORK/star/index_"
  test -s "$WORK/star/index/SA"
)
run_step star-index step_star_index

step_star_align() (
  set -e
  STAR --runThreadN "$THREADS" --genomeDir "$WORK/star/index" \
    --readFilesIn "$R1" "$R2" --readFilesCommand gunzip -c \
    --outSAMtype BAM SortedByCoordinate --quantMode GeneCounts \
    --outFileNamePrefix "$WORK/star/HBR_Rep1_"
  test -s "$WORK/star/HBR_Rep1_Aligned.sortedByCoord.out.bam"
  grep -E 'Number of input reads|Uniquely mapped reads (number|%)' "$WORK/star/HBR_Rep1_Log.final.out"
  mapped=$(grep 'Uniquely mapped reads number' "$WORK/star/HBR_Rep1_Log.final.out" | awk -F'|' '{gsub(/[ \t]/, "", $2); print $2}')
  test "$mapped" -gt 10000
  test -s "$WORK/star/HBR_Rep1_ReadsPerGene.out.tab"
  samtools index "$WORK/star/HBR_Rep1_Aligned.sortedByCoord.out.bam"
  samtools quickcheck -v "$WORK/star/HBR_Rep1_Aligned.sortedByCoord.out.bam"
)
run_step star-align step_star_align

# STAR 2.7.3a from the second environment builds its own index (the index format of 2.7.3a is
# 2.7.1a, the one of the main STAR is 2.7.4a, so the two do not mix) and aligns the same pair.
if [ "$STAR273A_PREFIX" != "skip" ]; then
  STAR_OLD="$STAR273A_PREFIX/bin/STAR"

  step_star273a_index() (
    set -e
    mkdir -p "$WORK/star273a/index"
    "$STAR_OLD" --runMode genomeGenerate --runThreadN "$THREADS" \
      --genomeDir "$WORK/star273a/index" --genomeFastaFiles "$FASTA" \
      --sjdbGTFfile "$GTF" --sjdbOverhang 100 --genomeSAindexNbases 11 \
      --outFileNamePrefix "$WORK/star273a/index_"
    test -s "$WORK/star273a/index/SA"
  )
  run_step star273a-index step_star273a_index

  step_star273a_align() (
    set -e
    "$STAR_OLD" --runThreadN "$THREADS" --genomeDir "$WORK/star273a/index" \
      --readFilesIn "$R1" "$R2" --readFilesCommand gunzip -c \
      --outSAMtype BAM SortedByCoordinate --quantMode GeneCounts \
      --outFileNamePrefix "$WORK/star273a/HBR_Rep1_"
    test -s "$WORK/star273a/HBR_Rep1_Aligned.sortedByCoord.out.bam"
    test -s "$WORK/star273a/HBR_Rep1_ReadsPerGene.out.tab"
    grep -E 'Number of input reads|Uniquely mapped reads (number|%)' "$WORK/star273a/HBR_Rep1_Log.final.out"
    samtools quickcheck -v "$WORK/star273a/HBR_Rep1_Aligned.sortedByCoord.out.bam"
  )
  run_step star273a-align step_star273a_align

  # On this pair the two STAR versions give the same ReadsPerGene table, byte for byte.
  step_star273a_counts() (
    set -e
    a="$WORK/star/HBR_Rep1_ReadsPerGene.out.tab"
    b="$WORK/star273a/HBR_Rep1_ReadsPerGene.out.tab"
    echo "sha256 STAR in the main environment  $(sha256_of "$a")"
    echo "sha256 STAR 2.7.3a                   $(sha256_of "$b")"
    if ! cmp -s "$a" "$b"; then
      echo "ReadsPerGene tables differ in $(diff "$a" "$b" | grep -c '^<') lines, first differences follow"
      diff "$a" "$b" | head -n 10
      exit 1
    fi
    echo "ReadsPerGene.out.tab is identical, $(wc -l < "$a" | tr -d ' ') lines"
  )
  run_step star273a-genecounts-equal step_star273a_counts
fi

step_feature_counts() (
  set -e
  mkdir -p "$WORK/featurecounts"
  featureCounts -T "$THREADS" -p --countReadPairs -t exon -g gene_id -a "$GTF" \
    -o "$WORK/featurecounts/counts.txt" "$WORK/star/HBR_Rep1_Aligned.sortedByCoord.out.bam"
  cat "$WORK/featurecounts/counts.txt.summary"
  assigned=$(awk '$1 == "Assigned" {print $2}' "$WORK/featurecounts/counts.txt.summary")
  test "$assigned" -gt 1000
)
run_step featurecounts step_feature_counts

step_salmon() (
  set -e
  salmon index -t "$WORK/ref/transcripts.fa" -i "$WORK/salmon/index" -p "$THREADS"
  salmon quant -i "$WORK/salmon/index" -l A -1 "$R1" -2 "$R2" -p "$THREADS" -o "$WORK/salmon/HBR_Rep1"
  test -s "$WORK/salmon/HBR_Rep1/quant.sf"
  total=$(awk 'NR > 1 {s += $5} END {printf "%d", s}' "$WORK/salmon/HBR_Rep1/quant.sf")
  echo "NumReads summed over transcripts: $total"
  test "$total" -gt 10000
)
run_step salmon-index-quant step_salmon

step_umi_tools() (
  set -e
  mkdir -p "$WORK/umi"
  umi_tools extract --bc-pattern=NNNNNNNN --ignore-read-pair-suffixes \
    -I "$WORK/reads/sub1.fastq.gz" --read2-in="$WORK/reads/sub2.fastq.gz" \
    -S "$WORK/umi/ex1.fastq.gz" --read2-out="$WORK/umi/ex2.fastq.gz" -L "$WORK/umi/extract.log"
  STAR --runThreadN "$THREADS" --genomeDir "$WORK/star/index" \
    --readFilesIn "$WORK/umi/ex1.fastq.gz" "$WORK/umi/ex2.fastq.gz" --readFilesCommand gunzip -c \
    --outSAMtype BAM SortedByCoordinate --outFileNamePrefix "$WORK/umi/umi_"
  samtools index "$WORK/umi/umi_Aligned.sortedByCoord.out.bam"
  umi_tools dedup --paired -I "$WORK/umi/umi_Aligned.sortedByCoord.out.bam" \
    -S "$WORK/umi/dedup.bam" -L "$WORK/umi/dedup.log"
  test -s "$WORK/umi/dedup.bam"
  grep -E 'Input Reads|reads out' "$WORK/umi/dedup.log" || true
  grep -q 'Reads: Input Reads' "$WORK/umi/dedup.log"
)
run_step umi_tools step_umi_tools

cat > "$WORK/scripts/smoke.R" <<'RSCRIPT'
args <- commandArgs(trailingOnly = TRUE)
quant_sf <- args[1]
suppressPackageStartupMessages({
  library(DESeq2)
  library(edgeR)
  library(limma)
  library(tximport)
  library(apeglm)
  library(pROC)
  library(rpart)
  library(data.table)
  library(jsonlite)
})
set.seed(1)
n_genes <- 300
condition <- factor(rep(c("A", "B"), each = 3))
base_mean <- rgamma(n_genes, shape = 2, scale = 60)
fold <- c(rep(3, 30), rep(1, n_genes - 30))
counts <- sapply(seq_along(condition), function(j) {
  mu <- if (condition[j] == "B") base_mean * fold else base_mean
  rnbinom(n_genes, mu = mu, size = 10)
})
storage.mode(counts) <- "integer"
rownames(counts) <- sprintf("gene%03d", seq_len(n_genes))
colnames(counts) <- sprintf("s%d", seq_along(condition))
coldata <- data.frame(condition = condition, row.names = colnames(counts))

dds <- DESeqDataSetFromMatrix(countData = counts, colData = coldata, design = ~ condition)
dds <- DESeq(dds, quiet = TRUE)
res <- results(dds)
n_sig <- sum(res$padj < 0.05, na.rm = TRUE)
cat("DESeq2 fitted", nrow(res), "genes,", n_sig, "with padj < 0.05\n")
stopifnot(nrow(res) == n_genes, n_sig >= 5)

shr <- lfcShrink(dds, coef = "condition_B_vs_A", type = "apeglm", quiet = TRUE)
stopifnot(nrow(shr) == n_genes, !all(is.na(shr$log2FoldChange)))
cat("apeglm shrinkage ran on", nrow(shr), "genes, median |LFC|", signif(median(abs(shr$log2FoldChange)), 3), "\n")

score <- as.numeric(log2(counts[1, ] + 1) + log2(counts[2, ] + 1))
roc_fit <- roc(response = condition, predictor = score, quiet = TRUE)
stopifnot(as.numeric(auc(roc_fit)) >= 0, as.numeric(auc(roc_fit)) <= 1)
cat("pROC AUC", signif(as.numeric(auc(roc_fit)), 4), "\n")

tree_data <- data.frame(condition = condition, t(log2(counts[1:30, ] + 1)))
tree <- rpart(condition ~ ., data = tree_data, control = rpart.control(minsplit = 2, cp = 0.01))
tree_pred <- predict(tree, tree_data, type = "class")
stopifnot(length(tree_pred) == length(condition))
cat("rpart tree with", nrow(tree$frame), "nodes, training accuracy", mean(tree_pred == tree_data$condition), "\n")

y <- DGEList(counts = counts, group = condition)
y <- normLibSizes(y)
design <- model.matrix(~ condition)
v <- voom(y, design)
fit <- eBayes(lmFit(v, design))
cat("edgeR and limma voom ran, top table rows:", nrow(topTable(fit, coef = 2, number = 5)), "\n")

txi <- tximport(quant_sf, type = "salmon", txOut = TRUE)
cat("tximport read", nrow(txi$counts), "transcripts from the salmon run\n")
stopifnot(nrow(txi$counts) > 500)

dt <- as.data.table(as.data.frame(res), keep.rownames = "gene")
cat(toJSON(list(deseq2_rows = nrow(dt), significant = n_sig), auto_unbox = TRUE), "\n")
cat("R_SMOKE_OK\n")
RSCRIPT

step_r() (
  set -e
  Rscript --vanilla "$WORK/scripts/smoke.R" "$WORK/salmon/HBR_Rep1/quant.sf"
  grep -q R_SMOKE_OK "$LOGS/r-deseq2-edger-limma-tximport.log"
)
run_step r-deseq2-edger-limma-tximport step_r

step_simpleaf() (
  set -e
  simpleaf set-paths
  simpleaf --help | head -n 5
)
run_step simpleaf-set-paths step_simpleaf

# The R environment with sva holds edgeR 4.8.x and limma 3.66.x because sva 3.58.0 pins them. Its
# Rscript must load every package from its own library and run a toy matrix through sva and DESeq2.
if [ "$R_SVA_PREFIX" != "skip" ]; then
  cat > "$WORK/scripts/smoke_r_sva.R" <<'RSVA'
suppressPackageStartupMessages({
  library(DESeq2)
  library(edgeR)
  library(limma)
  library(sva)
  library(apeglm)
  library(pROC)
  library(rpart)
  library(tximport)
  library(data.table)
  library(jsonlite)
})
prefix <- Sys.getenv("CONDA_PREFIX")
stopifnot(nzchar(prefix))
pk <- c("DESeq2", "edgeR", "limma", "sva", "apeglm", "pROC", "rpart", "tximport", "data.table", "jsonlite")
for (p in pk) cat(sprintf("%-11s %s\n", p, as.character(packageVersion(p))))
cat(R.version.string, "\n")
# Every one of these packages must come from this environment, not from another R library.
for (p in pk) stopifnot(startsWith(find.package(p), prefix))
# sva 3.58.0 pins edgeR 4.8.x and limma 3.66.x, which is the reason this environment exists.
stopifnot(startsWith(as.character(packageVersion("edgeR")), "4.8."))
stopifnot(startsWith(as.character(packageVersion("limma")), "3.66."))

set.seed(1)
n_genes <- 300
cond <- factor(rep(c("A", "B"), each = 6))
batch <- factor(rep(c("b1", "b2", "b3"), times = 4))
base_mean <- rgamma(n_genes, shape = 2, scale = 60)
fold <- c(rep(3, 30), rep(1, n_genes - 30))
bscale <- c(b1 = 1, b2 = 1.5, b3 = 0.7)
counts <- sapply(seq_along(cond), function(j) {
  mu <- if (cond[j] == "B") base_mean * fold else base_mean
  rnbinom(n_genes, mu = mu * bscale[[as.character(batch[j])]], size = 10)
})
storage.mode(counts) <- "integer"
rownames(counts) <- sprintf("gene%03d", seq_len(n_genes))
colnames(counts) <- sprintf("s%02d", seq_along(cond))
coldata <- data.frame(cond = cond, batch = batch, row.names = colnames(counts))

# sva, ComBat_seq on the counts and then svaseq
adj <- ComBat_seq(counts, batch = batch, group = cond)
stopifnot(identical(dim(adj), dim(counts)), !anyNA(adj))
cat("ComBat_seq ran, adjusted matrix", nrow(adj), "x", ncol(adj), "\n")
keep <- rowMeans(counts) > 5
mod <- model.matrix(~cond)
mod0 <- model.matrix(~1, data = data.frame(cond = cond))
sv <- svaseq(counts[keep, ], mod, mod0, n.sv = 1)
stopifnot(length(sv$sv) == length(cond))
cat("svaseq ran, one surrogate variable for", sum(keep), "genes\n")

# DESeq2 on the raw counts with the batch in the design, and on the ComBat_seq counts
dds <- DESeqDataSetFromMatrix(counts, coldata, ~batch + cond)
dds <- DESeq(dds, quiet = TRUE)
res <- results(dds, name = "cond_B_vs_A")
n_sig <- sum(res$padj < 0.05, na.rm = TRUE)
cat("DESeq2 with the batch in the design fitted", nrow(res), "genes,", n_sig, "with padj < 0.05\n")
stopifnot(nrow(res) == n_genes, n_sig >= 5)
dds_adj <- DESeqDataSetFromMatrix(adj, coldata, ~cond)
dds_adj <- DESeq(dds_adj, quiet = TRUE)
res_adj <- results(dds_adj)
n_sig_adj <- sum(res_adj$padj < 0.05, na.rm = TRUE)
cat("DESeq2 on the ComBat_seq counts fitted", nrow(res_adj), "genes,", n_sig_adj, "with padj < 0.05\n")
stopifnot(nrow(res_adj) == n_genes, n_sig_adj >= 5)

# apeglm shrinkage, pROC and rpart
shr <- lfcShrink(dds_adj, coef = "cond_B_vs_A", type = "apeglm", quiet = TRUE)
stopifnot(nrow(shr) == n_genes, !all(is.na(shr$log2FoldChange)))
cat("apeglm shrinkage ran on", nrow(shr), "genes, median |LFC|", signif(median(abs(shr$log2FoldChange)), 3), "\n")
score <- as.numeric(log2(counts[1, ] + 1) + log2(counts[2, ] + 1))
roc_fit <- roc(response = cond, predictor = score, quiet = TRUE)
stopifnot(as.numeric(auc(roc_fit)) >= 0, as.numeric(auc(roc_fit)) <= 1)
cat("pROC AUC", signif(as.numeric(auc(roc_fit)), 4), "\n")
tree_data <- data.frame(cond = cond, t(log2(counts[1:30, ] + 1)))
tree <- rpart(cond ~ ., data = tree_data, control = rpart.control(minsplit = 2, cp = 0.01))
tree_pred <- predict(tree, tree_data, type = "class")
stopifnot(length(tree_pred) == length(cond))
cat("rpart tree with", nrow(tree$frame), "nodes, training accuracy", mean(tree_pred == tree_data$cond), "\n")

# edgeR 4.8 and limma 3.66, the calls that the main smoke script makes
y <- DGEList(counts = counts, group = cond)
y <- normLibSizes(y)
design <- model.matrix(~cond)
v <- voom(y, design)
fit <- eBayes(lmFit(v, design))
cat("edgeR and limma voom ran, top table rows:", nrow(topTable(fit, coef = 2, number = 5)), "\n")
cat("R_SVA_SMOKE_OK\n")
RSVA

  step_r_sva() (
    set -e
    export PATH="$R_SVA_PREFIX/bin:$PATH"
    export CONDA_PREFIX="$R_SVA_PREFIX"
    test "$(command -v Rscript)" = "$R_SVA_PREFIX/bin/Rscript"
    Rscript --vanilla "$WORK/scripts/smoke_r_sva.R"
    grep -q R_SVA_SMOKE_OK "$LOGS/r-sva-combat-seq-deseq2.log"
  )
  run_step r-sva-combat-seq-deseq2 step_r_sva
fi

note ""
note "passed $PASSED, failed $FAILED"
if [ "$FAILED" -eq 0 ]; then
  note "SMOKE PASS"
  if [ "${SMOKE_KEEP:-0}" != "1" ] && [ "$#" -lt 3 ]; then
    rm -rf "$WORK"
  else
    echo "work folder kept at $WORK"
  fi
  exit 0
fi
note "SMOKE FAIL, work folder kept at $WORK"
exit 1
