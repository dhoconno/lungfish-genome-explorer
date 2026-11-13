# GSE162164 India cohort: the paper's DE, its two-gene signature, and the INSL3 stability checks.
# The same script runs on the deposited counts (step A) and on ours (step B).
#
# Usage: Rscript --vanilla de.R <counts.tsv> <samples.tsv> <india_degs.tsv> <out_dir> [nested]
#   counts.tsv      genes x samples, first column the gene symbol; sample columns named by the
#                   deposit's RICC column or by run accession (samples.tsv maps both)
#   india_degs.tsv  Supplementary Table 2, sheet India_DEGS (xlsx2tsv.py)
#   nested          1 (default) runs the nested leave-one-out; 0 skips it
# Needs DESeq2, sva, limma, rpart and pROC: the env-r-sva environment.
#
# What the paper says (Kulkarni 2021, Methods): DESeq2, FDR-adjusted p < 0.05 and log2 fold
# change +-1.4; "Following variance-stabilizing transformation and batch effect correction
# [sva package]", rpart with leave-one-out; ROC "AUC, measured by general linear modeling".
# Steps the paper does not state, and what this script assumes, are listed in README.md.
suppressPackageStartupMessages({
  library(DESeq2); library(sva); library(limma); library(rpart); library(pROC)
})
a <- commandArgs(trailingOnly = TRUE)
out <- a[4]; nested <- if (length(a) >= 5) a[5] == "1" else TRUE
dir.create(out, showWarnings = FALSE, recursive = TRUE)
set.seed(162164)
sheet <- read.delim(a[2], colClasses = "character")
cnt <- read.delim(a[1], check.names = FALSE, row.names = 1)
key <- if (all(colnames(cnt) %in% sheet$deposit_column)) "deposit_column" else "run"
sheet <- sheet[match(colnames(cnt), sheet[[key]]), ]
stopifnot(!anyNA(sheet$run))
cnt <- round(as.matrix(cnt)); storage.mode(cnt) <- "integer"
grp <- factor(sheet$group, levels = c("HIV", "TB"))
y <- as.integer(grp == "TB")
kv <- list(); put <- function(k, v) kv[[k]] <<- v
put("genes", nrow(cnt)); put("samples", ncol(cnt)); put("tb", sum(y)); put("hiv", sum(1 - y))

# 1. DESeq2, design ~ group, Wald test, MLE fold changes (Supplementary Table 2's stat column is
# log2FoldChange / lfcSE, so the paper did not shrink). Independent filtering at alpha = 0.05:
# an assumed step, since on the deposit it gives the paper's 77 India DEGs exactly and the default
# alpha = 0.1 gives 89 (the threshold moves from a baseMean of 8.9 to 5.2).
dds <- DESeqDataSetFromMatrix(cnt, data.frame(group = grp), ~ group)
dds <- DESeq(dds, quiet = TRUE)
res10 <- results(dds, contrast = c("group", "TB", "HIV"))
put("degs_alpha_0.1", sum(res10$padj < 0.05 & abs(res10$log2FoldChange) >= 1.4, na.rm = TRUE))
res <- results(dds, contrast = c("group", "TB", "HIV"), alpha = 0.05)
put("tested", sum(!is.na(res$padj)))
tab <- data.frame(gene = rownames(res), as.data.frame(res))
write.table(tab, file.path(out, "de_results.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
deg <- tab[!is.na(tab$padj) & tab$padj < 0.05 & abs(tab$log2FoldChange) >= 1.4, ]
put("degs", nrow(deg)); put("degs_up", sum(deg$log2FoldChange > 0))
put("degs_down", sum(deg$log2FoldChange < 0))
paper <- read.delim(a[3], check.names = FALSE)
put("paper_degs", nrow(paper)); put("shared_with_paper", length(intersect(deg$gene, paper$Gene)))
put("paper_degs_absent_from_counts", sum(!paper$Gene %in% rownames(cnt)))
m <- merge(paper, tab, by.x = "Gene", by.y = "gene", suffixes = c(".paper", ".ours"))
put("paper_genes_matched", nrow(m))
put("basemean_median_ratio", median(m$baseMean.ours / m$baseMean.paper))
put("basemean_max_abs_rel_diff", max(abs(m$baseMean.ours / m$baseMean.paper - 1)))
put("lfc_max_abs_diff", max(abs(m$log2FoldChange.ours - m$log2FoldChange.paper)))
put("lfc_pearson", cor(m$log2FoldChange.ours, m$log2FoldChange.paper))
put("padj_spearman", cor(m$padj.ours, m$padj.paper, method = "spearman", use = "complete.obs"))
write.table(m, file.path(out, "paper_degs_vs_ours.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
for (g in c("INSL3", "RAB20")) {
  r <- tab[tab$gene == g, ]
  if (nrow(r)) {
    put(paste0(g, "_lfc"), r$log2FoldChange); put(paste0(g, "_lfcSE"), r$lfcSE)
    put(paste0(g, "_padj"), r$padj); put(paste0(g, "_baseMean"), r$baseMean)
    put(paste0(g, "_is_deg"), g %in% deg$gene)
    put(paste0(g, "_counts_TB"), paste(cnt[g, y == 1], collapse = ","))
    put(paste0(g, "_counts_HIV"), paste(cnt[g, y == 0], collapse = ","))
    put(paste0(g, "_zero_samples"), sum(cnt[g, ] == 0))
  }
}

# 2. VST then sva. The paper names no batch, and in the paper sva corrected India and Uganda
# together. With India alone the script estimates surrogate variables with sva (the group in the
# full model) and removes them with limma's removeBatchEffect, keeping the group effect.
vsd <- assay(vst(dds, blind = TRUE))
mod <- model.matrix(~ grp); mod0 <- model.matrix(~ 1, data.frame(grp))
nsv <- num.sv(vsd, mod, method = "be"); put("sva_n_sv", nsv)
clean <- if (nsv > 0) {
  sv <- sva(vsd, mod, mod0, n.sv = nsv)$sv
  removeBatchEffect(vsd, covariates = sv, design = mod)
} else vsd
sig <- c("INSL3", "RAB20")
auc_glm <- function(x, lab) {
  d <- data.frame(lab = lab, x)
  f <- suppressWarnings(glm(lab ~ ., data = d, family = binomial))
  p <- fitted(f)
  r <- roc(lab, p, quiet = TRUE, direction = "<", levels = c(0, 1))
  list(auc = as.numeric(auc(r)), ci = as.numeric(ci.auc(r, method = "delong"))[c(1, 3)],
       miss = sum((p > 0.5) != lab))
}
loo_glm <- function(x, lab) {
  p <- sapply(seq_along(lab), function(i) {
    d <- data.frame(lab = lab[-i], x[-i, , drop = FALSE])
    f <- suppressWarnings(glm(lab ~ ., data = d, family = binomial))
    predict(f, newdata = x[i, , drop = FALSE], type = "response")
  })
  as.numeric(auc(roc(lab, p, quiet = TRUE, direction = "<", levels = c(0, 1))))
}
for (nm in c("vst", "vst_sva")) {
  X <- if (nm == "vst") vsd else clean
  if (!all(sig %in% rownames(X))) next
  x <- as.data.frame(t(X[sig, , drop = FALSE]))
  r <- auc_glm(x, y)
  put(paste0("auc2_", nm), r$auc); put(paste0("auc2_", nm, "_ci"), paste(round(r$ci, 3), collapse = "-"))
  put(paste0("auc2_", nm, "_misclassified"), r$miss)
  put(paste0("auc2_", nm, "_loo"), loo_glm(x, y))
  for (g in sig) put(paste0("auc1_", g, "_", nm), auc_glm(x[, g, drop = FALSE], y)$auc)
}
# The tree the paper describes, on India alone: rpart on the DEGs after VST and sva.
if (nrow(deg) > 0) {
  d <- data.frame(lab = factor(y), t(clean[deg$gene, , drop = FALSE]), check.names = TRUE)
  tr <- rpart(lab ~ ., data = d, method = "class")
  used <- setdiff(unique(as.character(tr$frame$var)), "<leaf>")
  put("tree_genes_india_only", paste(used, collapse = ","))
  put("tree_misclassified_resub", sum(predict(tr, d, type = "class") != d$lab))
}

# 3. Nested leave-one-out (R2-STAT claim 4): DE, VST, sva and the tree inside each fold, so the
# held-out sample never shapes the gene choice. sva's fsva freezes the training factors for the
# held-out sample; the VST of the held-out sample uses the training dispersion fit.
if (nested) {
  pt <- pg <- numeric(length(y)); picks <- character(length(y))
  for (i in seq_along(y)) {
    tr_i <- setdiff(seq_along(y), i)
    d1 <- DESeqDataSetFromMatrix(cnt[, tr_i], data.frame(group = grp[tr_i]), ~ group)
    d1 <- DESeq(d1, quiet = TRUE)
    r1 <- results(d1, contrast = c("group", "TB", "HIV"), alpha = 0.05)
    g1 <- rownames(r1)[which(r1$padj < 0.05 & abs(r1$log2FoldChange) >= 1.4)]
    if (length(g1) < 2) g1 <- rownames(r1)[order(r1$padj)][1:2]
    v1 <- vst(d1, blind = TRUE)
    dt <- DESeqDataSetFromMatrix(cnt[, i, drop = FALSE], data.frame(group = grp[i]), ~ 1)
    gm <- exp(rowMeans(log(counts(d1, normalized = FALSE) + 0.5)))
    dt <- estimateSizeFactors(dt, geoMeans = gm)
    dispersionFunction(dt) <- dispersionFunction(d1)
    vt <- assay(varianceStabilizingTransformation(dt, blind = FALSE))
    a1 <- assay(v1); m1 <- model.matrix(~ grp[tr_i]); m0 <- model.matrix(~ 1, data.frame(tr_i))
    k <- num.sv(a1, m1, method = "be")
    if (k > 0) {
      s1 <- sva(a1, m1, m0, n.sv = k)
      fs <- fsva(a1, m1, s1, vt, method = "exact")
      a1 <- fs$db; vt <- fs$new
    }
    dtr <- data.frame(lab = factor(y[tr_i]), t(a1[g1, , drop = FALSE]), check.names = TRUE)
    dte <- data.frame(t(vt[g1, , drop = FALSE]), check.names = TRUE)
    tr <- rpart(lab ~ ., data = dtr, method = "class")
    pt[i] <- predict(tr, dte, type = "prob")[, "1"]
    used <- setdiff(unique(as.character(tr$frame$var)), "<leaf>")
    picks[i] <- paste(used, collapse = ",")
    if (length(used) == 0) used <- make.names(g1[1])
    xg <- data.frame(dtr[, used, drop = FALSE])
    f <- suppressWarnings(glm(y[tr_i] ~ ., data = xg, family = binomial))
    pg[i] <- predict(f, newdata = dte[, used, drop = FALSE], type = "response")
  }
  put("nested_auc_tree", as.numeric(auc(roc(y, pt, quiet = TRUE, direction = "<", levels = c(0, 1)))))
  put("nested_auc_glm_on_tree_genes", as.numeric(auc(roc(y, pg, quiet = TRUE, direction = "<", levels = c(0, 1)))))
  put("nested_folds_picking_INSL3", sum(grepl("(^|,)INSL3(,|$)", picks)))
  put("nested_folds_picking_RAB20", sum(grepl("(^|,)RAB20(,|$)", picks)))
  tp <- sort(table(unlist(strsplit(picks[picks != ""], ","))), decreasing = TRUE)
  put("nested_top_picks", paste(names(tp)[1:min(5, length(tp))], tp[1:min(5, length(tp))], sep = ":", collapse = ","))
  write.table(data.frame(run = sheet$run, group = grp, p_tree = pt, p_glm = pg, picks = picks),
              file.path(out, "nested_loo.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
}

# 4. INSL3 stability. The signature's genes are fixed here, so these isolate counting noise.
# Scale: log2 of size-factor normalized counts plus 1, the same for every perturbation.
if (all(sig %in% rownames(cnt))) {
  sf <- sizeFactors(dds)
  lg <- function(k) log2(t(t(k) / sf) + 1)
  base <- as.data.frame(t(lg(cnt[sig, ])))
  put("auc2_lognorm", auc_glm(base, y)$auc)
  put("auc1_INSL3_lognorm", auc_glm(base[, "INSL3", drop = FALSE], y)$auc)
  run_pert <- function(fun, B = 1000) {
    v <- replicate(B, {
      k <- cnt[sig, ]; k["INSL3", ] <- fun(k["INSL3", ])
      auc_glm(as.data.frame(t(lg(k))), y)$auc
    })
    c(median = median(v), lo = unname(quantile(v, 0.025)), hi = unname(quantile(v, 0.975)))
  }
  # A second library of the same RNA would differ by at least Poisson noise.
  p1 <- run_pert(function(k) rpois(length(k), k))
  # Half and a quarter of the depth: binomial thinning of the observed counts.
  p2 <- run_pert(function(k) rbinom(length(k), k, 0.5))
  p3 <- run_pert(function(k) rbinom(length(k), k, 0.25))
  for (nm in c("poisson", "half_depth", "quarter_depth")) {
    v <- switch(nm, poisson = p1, half_depth = p2, quarter_depth = p3)
    put(paste0("insl3_", nm, "_auc2"), paste(round(v, 3), collapse = "/"))
  }
  # Optimism of the apparent two-gene AUC: bootstrap the samples within groups (Harrell).
  draw <- function(x) x[sample.int(length(x), replace = TRUE)]
  opt <- replicate(500, tryCatch({
    b <- c(draw(which(y == 1)), draw(which(y == 0)))
    db <- data.frame(lab = y[b], base[b, ])
    f <- suppressWarnings(glm(lab ~ ., data = db, family = binomial))
    ab <- as.numeric(auc(roc(y[b], fitted(f), quiet = TRUE, direction = "<", levels = c(0, 1))))
    ao <- as.numeric(auc(roc(y, predict(f, newdata = base, type = "response"), quiet = TRUE,
                             direction = "<", levels = c(0, 1))))
    ab - ao
  }, error = function(e) NA_real_))
  put("auc2_lognorm_optimism", mean(opt, na.rm = TRUE))
  put("auc2_lognorm_corrected", auc_glm(base, y)$auc - mean(opt, na.rm = TRUE))
  put("insl3_mean_count", mean(cnt["INSL3", ])); put("insl3_max_count", max(cnt["INSL3", ]))
}
s <- data.frame(key = names(kv), value = vapply(kv, function(v) format(v, digits = 6), ""))
write.table(s, file.path(out, "summary.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
print(s, row.names = FALSE)
