# A against B with limma, as the paper's titration metric defines DE: "significant at a
# Benjamini-Yekutieli corrected FDR of 5% in an empirical Bayes moderated t-test across the
# expression level estimates of samples A and B (limma)" (PMC4321899, Online Methods).
# The same script runs on the deposited counts and on ours.
# Usage: Rscript --vanilla de.R <counts.tsv> <out.tsv>
#   counts.tsv: first column gene id, then one column a library named <sample>_<library>
#   (A_1 ... D_5). Rows whose id starts with "ERCC-" (the spike-ins, not the human ERCC1 to ERCC8 genes) are left out of DE and normalisation.
# Model: edgeR filterByExpr on the four groups, TMM, voom, lmFit on ~0 + group, contrast A - B,
# eBayes, BY adjustment. The paper does not name its normalisation or filter (see README).
suppressPackageStartupMessages({ library(limma); library(edgeR) })
a <- commandArgs(trailingOnly = TRUE)
d <- read.delim(a[1], check.names = FALSE)
ids <- as.character(d[[1]]); m <- as.matrix(d[, -1]); rownames(m) <- ids
m <- m[!grepl("^ERCC-", ids), , drop = FALSE]
grp <- factor(sub("_.*", "", colnames(m)), levels = c("A", "B", "C", "D"))
y <- DGEList(m, group = grp)
keep <- filterByExpr(y, group = grp)
y <- calcNormFactors(y[keep, , keep.lib.sizes = FALSE])
des <- model.matrix(~ 0 + grp); colnames(des) <- levels(grp)
v <- voom(y, des)
fit <- eBayes(contrasts.fit(lmFit(v, des), makeContrasts(A - B, levels = des)))
tt <- topTable(fit, number = Inf, sort.by = "none", adjust.method = "BY")
tt$DE <- tt$adj.P.Val < 0.05
out <- data.frame(gene_id = rownames(tt), logFC = tt$logFC, AveExpr = tt$AveExpr,
                  t = tt$t, P = tt$P.Value, BY = tt$adj.P.Val, DE = tt$DE)
write.table(out, a[2], sep = "\t", quote = FALSE, row.names = FALSE)
cat(sprintf("%s: %d genes tested of %d, %d DE at BY 5%% (%d up in A, %d up in B)\n",
            basename(a[1]), nrow(out), nrow(m), sum(out$DE),
            sum(out$DE & out$logFC > 0), sum(out$DE & out$logFC < 0)))
