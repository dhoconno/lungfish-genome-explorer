# DESeq2, PBL against CSF, in the paper's groups I to III (PMC9478118, Results and Figure 8C).
# Usage: Rscript de.R <samples.tsv> <counts.tsv> <out_prefix>
# counts.tsv: gene_id then one column a sample, named as in samples.tsv (B26, C95, ...).
# The paper names DESeq2 and the DEG cut (log2FC beyond 1, padj under 0.05) but not the design,
# the prefilter or the version. Assumed: design ~ tissue, no prefilter, Wald test, unshrunk log2FC,
# BH padj, contrast PBL over CSF (so the paper's "+" genes, high in PBL, are positive).
# A paired design (~ patient + tissue) is written beside it as a sensitivity, never as the score.
suppressPackageStartupMessages(library(DESeq2))
args <- commandArgs(trailingOnly = TRUE)
samples <- read.delim(args[1], stringsAsFactors = FALSE)
counts <- read.delim(args[2], row.names = 1, check.names = FALSE)
out <- args[3]
cat("DESeq2", as.character(packageVersion("DESeq2")), "R", R.version.string, "\n")
for (g in c("I", "II", "III")) {
  s <- samples[samples$group == g, ]
  s <- s[s$sample %in% colnames(counts), ]
  m <- as.matrix(counts[, s$sample])
  storage.mode(m) <- "integer"
  m <- m[rowSums(m) > 0, ]
  cd <- data.frame(row.names = s$sample, tissue = factor(s$tissue, levels = c("CSF", "PBL")),
                   patient = factor(s$patient))
  for (design in c("unpaired", "paired")) {
    f <- if (design == "unpaired") ~ tissue else ~ patient + tissue
    dds <- DESeqDataSetFromMatrix(m, cd, f)
    dds <- DESeq(dds, quiet = TRUE)
    res <- results(dds, contrast = c("tissue", "PBL", "CSF"), alpha = 0.05)
    df <- data.frame(gene_id = rownames(res), baseMean = res$baseMean, log2FC = res$log2FoldChange,
                     pvalue = res$pvalue, padj = res$padj)
    df <- df[order(df$padj, -abs(df$log2FC)), ]
    write.table(df, sprintf("%s_group%s_%s.tsv", out, g, design), sep = "\t", quote = FALSE, row.names = FALSE)
    up <- sum(df$padj < 0.05 & df$log2FC > 1, na.rm = TRUE)
    down <- sum(df$padj < 0.05 & df$log2FC < -1, na.rm = TRUE)
    cat(sprintf("group %s %s: samples %d, genes %d, up in PBL %d, down %d\n", g, design, ncol(m), nrow(m), up, down))
  }
}
