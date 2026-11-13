#!/usr/bin/env Rscript
# Gene counts from salmon quant.sf files, as nf-core/rnaseq 3.8.1 module SALMON_TXIMPORT does it
# (modules/local/salmon_tximport.nf, bin/salmon_tximport.r):
#   txi <- tximport(files, type = "salmon", txOut = TRUE)
#   gi  <- summarizeToGene(txi, tx2gene = rowdata[, 1:2])      # countsFromAbundance "no"
#   salmon.merged.gene_counts.tsv = gene_id, gene_name, then gi$counts, one column a sample
# tx2gene is the three-column table of SALMON_TX2GENE (transcript, gene_id, gene_name, no header).
# Transcripts of quant.sf missing from tx2gene become their own gene there; none is expected here,
# so the script reports their number. The nf-core script builds a SummarizedExperiment around the
# same tables; the counts do not depend on it, so plain tximport is used.
#
# Usage: Rscript tximport.R <salmon_variant_dir> <tx2gene.tsv> <out.tsv> <name> [<name> ...]
#   reads <salmon_variant_dir>/<name>/quant.sf for each name
suppressPackageStartupMessages(library(tximport))
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4) stop("usage: tximport.R <salmon_variant_dir> <tx2gene.tsv> <out.tsv> <name> ...")
dir <- args[1]; t2g_path <- args[2]; out <- args[3]; samples <- args[-(1:3)]

files <- file.path(dir, samples, "quant.sf")
names(files) <- samples
missing <- files[!file.exists(files)]
if (length(missing) > 0) stop("missing quant.sf: ", paste(missing, collapse = ", "))

rowdata <- read.csv(t2g_path, sep = "\t", header = FALSE, colClasses = "character")
colnames(rowdata) <- c("tx", "gene_id", "gene_name")

txi <- tximport(files, type = "salmon", txOut = TRUE)
extra <- setdiff(rownames(txi$counts), rowdata$tx)
cat("transcripts in quant.sf:", nrow(txi$counts), " not in tx2gene:", length(extra), "\n")
if (length(extra) > 0) {
  rowdata <- rbind(rowdata, data.frame(tx = extra, gene_id = extra, gene_name = extra))
}
gi <- summarizeToGene(txi, tx2gene = rowdata[, 1:2])
growdata <- unique(rowdata[, 2:3])
growdata <- growdata[match(rownames(gi$counts), growdata$gene_id), ]
res <- data.frame(gene_id = rownames(gi$counts), gene_name = growdata$gene_name, gi$counts,
                  check.names = FALSE, stringsAsFactors = FALSE)
dir.create(dirname(out), showWarnings = FALSE, recursive = TRUE)
write.table(res, out, sep = "\t", quote = FALSE, row.names = FALSE)
cat("genes:", nrow(res), " samples:", length(samples), " column sums:",
    paste(sprintf("%s %.0f", samples, colSums(gi$counts)), collapse = ", "), "\n")
