# DESeq2 for GSE290671 (C7), each day against -8 DPI.
#
# The paper (Methods, Transcriptomic analysis): "The sequencing batch effect was
# regressed using SVA ComBat-seq v3.54.0 ... Postexposure samples were binned
# by day (DPI) and compared to baseline (-8 DPI) using DESeq2 v1.46.0.
# Significantly differentially expressed (DE) genes for each comparison had an
# FDR-adjusted p-value < 0.05 and a shrunken log2 fold change >2 or <-2."
# It states no design formula, no ComBat-seq covariate, no shrinkage method and
# no prefilter. This script runs four variants: ComBat-seq on or off, and the
# design ~ day or ~ animal + day. ComBat-seq runs with the batch only, because
# batch B holds exactly days 3 and 10, so a day covariate is confounded with
# batch and ComBat-seq cannot take it. Shrinkage is lfcShrink's default in
# DESeq2 1.46.0, apeglm. No prefilter. The seven BOMV rows are dropped before
# DESeq2, so the virus stays out of the size factors.
#
# Usage:
#   Rscript de.R COUNTS.tsv[.gz] SAMPLES.tsv OUT_PREFIX COMBAT DESIGN [THREADS]
# COMBAT is yes or no, DESIGN is day or animal_day.
# The count columns are sample01 to sample36, which map in order onto the GEO
# samples sorted by GSM accession (the series matrix order).

suppressPackageStartupMessages({
  library(DESeq2)
  library(sva)
  library(BiocParallel)
})

args <- commandArgs(trailingOnly = TRUE)
counts_path <- args[1]
samples_path <- args[2]
out <- args[3]
combat <- args[4]
design_name <- args[5]
threads <- if (length(args) >= 6) as.integer(args[6]) else 1L
register(MulticoreParam(threads))
cat("DESeq2", as.character(packageVersion("DESeq2")),
  "sva", as.character(packageVersion("sva")),
  "apeglm", as.character(packageVersion("apeglm")), "\n")

bomv <- c("NP", "VP35", "VP40", "GP", "VP30", "VP24", "L")
tab <- read.delim(counts_path, check.names = FALSE)
names_col <- tab[[1]]
stopifnot(identical(tail(names_col, 7), bomv))
mat <- as.matrix(tab[-seq(nrow(tab) - 6, nrow(tab)), -1])
gene <- head(names_col, -7)
rownames(mat) <- make.unique(gene)
storage.mode(mat) <- "integer"

s <- read.delim(samples_path, check.names = FALSE)
s <- s[order(s$geo_sample), ]
s$sample <- sprintf("sample%02d", seq_len(nrow(s)))
s$day <- as.integer(sub(" DPI", "", s$time_point))
s$batch <- sub(".*batch: ", "", s$geo_characteristics)
s$animal <- gsub(" ", "", s$animal_or_donor)
cd <- s[match(colnames(mat), s$sample), c("sample", "geo_sample", "day", "animal", "batch")]
stopifnot(!anyNA(cd$day))
lab <- function(d) ifelse(d < 0, paste0("Dm", -d), paste0("D", d))
days <- sort(unique(cd$day))
cd$day <- factor(lab(cd$day), levels = lab(days))
cd$animal <- factor(cd$animal)
rownames(cd) <- cd$sample
write.table(cd, paste0(out, ".coldata.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
print(table(cd$day, cd$batch))

if (combat == "yes") {
  mat <- ComBat_seq(mat, batch = cd$batch, group = NULL)
}
form <- if (design_name == "day") ~ day else ~ animal + day
dds <- DESeqDataSetFromMatrix(mat, cd, form)
dds <- DESeq(dds, parallel = threads > 1)
sf <- sizeFactors(dds)
write.table(data.frame(sample = names(sf), size_factor = sf),
  paste0(out, ".size_factors.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)

marker <- c("ISG15", "IFIT2", "OAS3", "MMP8", "ELANE", "LCN2", "CXCL8", "CCL7", "CCL2")
totals <- list()
markers <- list()
for (d in setdiff(levels(cd$day), "Dm8")) {
  coef <- paste0("day_", d, "_vs_Dm8")
  res <- results(dds, name = coef, alpha = 0.05)
  shr <- lfcShrink(dds, coef = coef, res = res, type = "apeglm", quiet = TRUE)
  up <- sum(shr$padj < 0.05 & shr$log2FoldChange > 2, na.rm = TRUE)
  down <- sum(shr$padj < 0.05 & shr$log2FoldChange < -2, na.rm = TRUE)
  totals[[d]] <- data.frame(day = d, up = up, down = down, total = up + down)
  m <- shr[marker, c("log2FoldChange", "padj")]
  markers[[d]] <- data.frame(day = d, gene = marker, lfc_shrunk = m$log2FoldChange,
    padj = m$padj, lfc_mle = res[marker, "log2FoldChange"])
  write.table(data.frame(gene = rownames(shr), as.data.frame(shr)),
    gzfile(paste0(out, ".", d, ".tsv.gz")), sep = "\t", quote = FALSE, row.names = FALSE)
}
tot <- do.call(rbind, totals)
mk <- do.call(rbind, markers)
write.table(tot, paste0(out, ".totals.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
write.table(mk, paste0(out, ".markers.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
print(tot)
