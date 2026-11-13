# Count STAR BAM files with Rsubread featureCounts, as GSE290671 did.
#
# The paper: "transcript-aligning reads were quantified with Rsubread
# featureCounts v2.20.0" (Methods, Transcriptomic analysis). It names no
# argument, so the default mode passes only the annotation and leaves every
# other argument at Rsubread 2.20.0's default. Those defaults differ from the
# subread command line: isPairedEnd = FALSE counts each mate as a read, and
# countMultiMappingReads = TRUE counts every alignment of a multimapper.
#
# Usage:
#   Rscript count.R GTF OUT_PREFIX MODE THREADS BAM [BAM ...]
# MODE is one of
#   default   Rsubread defaults with the GTF (the paper's stated call)
#   pairs     isPairedEnd = TRUE, fragments counted once
#   unique    countMultiMappingReads = FALSE
# Writes OUT_PREFIX.counts.tsv (GeneID then one column a BAM, in GTF order)
# and OUT_PREFIX.summary.tsv (featureCounts' assignment table).

suppressPackageStartupMessages(library(Rsubread))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 5) stop("usage: count.R GTF OUT_PREFIX MODE THREADS BAM...")
gtf <- args[1]
out <- args[2]
mode <- args[3]
threads <- as.integer(args[4])
bams <- args[5:length(args)]

cat("Rsubread", as.character(packageVersion("Rsubread")), "mode", mode, "\n")

extra <- switch(mode,
  default = list(),
  pairs = list(isPairedEnd = TRUE),
  pairs_reads = list(isPairedEnd = TRUE, countReadPairs = FALSE),
  unique = list(countMultiMappingReads = FALSE),
  pairs_primary = list(isPairedEnd = TRUE, primaryOnly = TRUE),
  pairs_unique = list(isPairedEnd = TRUE, countMultiMappingReads = FALSE),
  gene_pairs = list(isPairedEnd = TRUE, GTF.featureType = "gene"),
  gene_pairs_reads = list(isPairedEnd = TRUE, countReadPairs = FALSE,
    GTF.featureType = "gene"),
  NULL
)
if (is.null(extra)) {
  # Any other MODE is a comma list of featureCounts arguments, for example
  # isPairedEnd=TRUE,allowMultiOverlap=TRUE,GTF.featureType=gene
  kv <- strsplit(strsplit(mode, ",")[[1]], "=")
  extra <- setNames(lapply(kv, function(p) type.convert(p[2], as.is = TRUE)),
    vapply(kv, `[`, "", 1))
}
print(extra)

run_fc <- function(ex) do.call(featureCounts, c(list(
  files = bams,
  annot.ext = gtf,
  isGTFAnnotationFile = TRUE,
  nthreads = threads
), ex))
fc <- tryCatch(run_fc(extra), error = function(e) e)
if (inherits(fc, "error")) {
  # Rsubread stops on a BAM with no reads at all when isPairedEnd = TRUE (a
  # BOMV slice of a run with no virus read). Count it as single end, and keep
  # the zero counts only if no read was seen at all. Otherwise the first
  # error stands.
  ex2 <- extra
  ex2$isPairedEnd <- FALSE
  ex2$countReadPairs <- NULL
  fc2 <- tryCatch(run_fc(ex2), error = function(e) NULL)
  if (isTRUE(extra$isPairedEnd) && !is.null(fc2) && sum(fc2$stat[, -1]) == 0) {
    cat("no reads in", bams, "so every count is zero\n")
    fc <- fc2
  } else {
    stop(fc)
  }
}

counts <- fc$counts
# Name each column by the run: the BAM's folder for STAR's Aligned.out.bam
# (run.sh names the folder after the run), else the file name up to its
# first dot (a slice, <run>.OK633884.1.bam).
run_name <- function(b) {
  if (basename(b) == "Aligned.out.bam") basename(dirname(b)) else sub("\\..*$", "", basename(b))
}
runs <- vapply(bams, run_name, "", USE.NAMES = FALSE)
colnames(counts) <- runs
tab <- data.frame(GeneID = rownames(counts), counts, check.names = FALSE)
write.table(tab, paste0(out, ".counts.tsv"), sep = "\t", quote = FALSE,
  row.names = FALSE)

stat <- fc$stat
colnames(stat) <- c("Status", runs)
write.table(stat, paste0(out, ".summary.tsv"), sep = "\t", quote = FALSE,
  row.names = FALSE)
