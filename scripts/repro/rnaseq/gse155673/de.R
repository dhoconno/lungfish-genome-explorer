# Donor pseudobulk DE of myeloid cells, COVID-19 (7) against healthy (5): edgeR quasi-likelihood
# with filterByExpr and TMM, FDR 0.05. The last line printed is "<up>/<down>", which claims.py
# records beside the cell-level total (R2-STAT GSE155673 item 5: report both, not a gate).
# Usage: Rscript --vanilla de.R pseudobulk.tsv donors.tsv out.tsv
suppressPackageStartupMessages(library(edgeR))
a <- commandArgs(trailingOnly = TRUE)
x <- as.matrix(read.delim(a[1], row.names = 1, check.names = FALSE))
d <- read.delim(a[2])
stopifnot(identical(colnames(x), d$library))
grp <- factor(d$group, levels = c("Healthy", "COVID"))
y <- DGEList(x, group = grp)
keep <- filterByExpr(y, group = grp)
y <- calcNormFactors(y[keep, , keep.lib.sizes = FALSE])
des <- model.matrix(~grp)
fit <- glmQLFit(estimateDisp(y, des), des)
tt <- topTags(glmQLFTest(fit, coef = 2), n = Inf)$table
write.table(data.frame(gene_id = rownames(tt), tt), a[3], sep = "\t", quote = FALSE, row.names = FALSE)
sig <- tt$FDR < 0.05
cat(sprintf("%d genes tested, edgeR %s\n", nrow(tt), as.character(packageVersion("edgeR"))))
cat(sprintf("%d/%d\n", sum(sig & tt$logFC > 0), sum(sig & tt$logFC < 0)))
