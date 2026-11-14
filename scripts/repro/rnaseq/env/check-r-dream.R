# Proof for the R environment with dream (lane DATA-DREAM, ruling ADJ-BIO-51 item 3).
# Run it with the Rscript of the environment, from any folder, as
#   /Volumes/lge_scratch/lge/rnaseq/env-r-dream/bin/Rscript --vanilla check-r-dream.R
# Part 1 prints the version of every package the edgeR, limma voom and dream template loads and requires each one
# to come from the library of this environment. Part 2 runs the example of dream() from variancePartition.
# Part 3 runs a small count table through edgeR, voomWithDreamWeights and dream with the random term (1|animal),
# once with the default degrees of freedom and once with Kenward-Roger. The last line is DREAM_ENV_OK.

options(warn = 1)
started <- Sys.time()
pdf(NULL)

stopifnot(R.version$major == "4", startsWith(R.version$minor, "5"))
cat("R:", R.version.string, "\n")
cat("platform:", R.version$platform, "\n")
lib <- normalizePath(file.path(R.home(), "library"))
cat("environment library:", lib, "\n\n")

# ---- Part 1, versions ----
pkgs <- c("variancePartition", "limma", "edgeR", "lme4", "lmerTest", "pbkrtest", "BiocParallel", "Biobase",
          "Matrix", "MASS", "data.table", "jsonlite")
t1 <- system.time({
  rows <- lapply(pkgs, function(p) {
    suppressPackageStartupMessages(library(p, character.only = TRUE))
    path <- normalizePath(find.package(p))
    data.frame(package = p, version = as.character(packageVersion(p)),
               in_env_library = startsWith(path, lib), stringsAsFactors = FALSE)
  })
})
versions <- do.call(rbind, rows)
print(versions, row.names = FALSE)
stopifnot(all(versions$in_env_library))
cat(sprintf("\nloading the %d packages took %.1f s\n\n", length(pkgs), t1[["elapsed"]]))

# ---- Part 2, the example of dream() ----
cat("== Part 2, example(dream) of variancePartition ==\n")
t2 <- system.time(
  example("dream", package = "variancePartition", echo = TRUE, ask = FALSE, run.donttest = FALSE)
)
cat(sprintf("\nexample(dream) took %.1f s\n\n", t2[["elapsed"]]))

# ---- Part 3, the template shape: counts, edgeR, voomWithDreamWeights, dream with (1|animal) ----
cat("== Part 3, counts to edgeR to voomWithDreamWeights to dream with (1|animal) ==\n")
library(BiocParallel)
set.seed(20261114)
n_animal <- 8
day_levels <- c("d3", "d7", "d10")
info <- data.frame(
  animal = factor(rep(paste0("A", seq_len(n_animal)), each = length(day_levels))),
  day = factor(rep(day_levels, times = n_animal), levels = day_levels)
)
rownames(info) <- paste0("S", seq_len(nrow(info)))
n_gene <- 400
base <- rexp(n_gene, rate = 1 / 150) + 5
animal_eff <- exp(rnorm(n_animal, 0, 0.35))[as.integer(info$animal)]
day_eff <- matrix(1, n_gene, nrow(info))
up <- seq_len(40)
day_eff[up, info$day == "d10"] <- 2.5
mu <- outer(base, animal_eff) * day_eff
counts <- matrix(rnbinom(length(mu), mu = mu, size = 25), nrow = n_gene,
                 dimnames = list(sprintf("G%04d", seq_len(n_gene)), rownames(info)))
dge <- DGEList(counts)
keep <- filterByExpr(dge, group = info$day)
dge <- dge[keep, , keep.lib.sizes = FALSE]
dge <- calcNormFactors(dge)
cat("genes kept by filterByExpr:", nrow(dge), "of", n_gene, "\n")

# edgeR and limma voom with the fixed effect alone, the other two blocks of the template
design <- model.matrix(~ day, info)
v <- voom(dge, design)
fit_limma <- eBayes(lmFit(v, design))
cat("limma voom, genes with adj.P.Val < 0.05 for dayd10:",
    sum(topTable(fit_limma, coef = "dayd10", number = Inf)$adj.P.Val < 0.05), "\n")
dge_e <- estimateDisp(dge, design)
qlf <- glmQLFTest(glmQLFit(dge_e, design), coef = "dayd10")
cat("edgeR quasi-likelihood, genes with FDR < 0.05 for dayd10:",
    sum(topTags(qlf, n = Inf)$table$FDR < 0.05), "\n")

# dream with the random term
form <- ~ day + (1 | animal)
t3 <- system.time({
  vobj <- voomWithDreamWeights(dge, form, info, BPPARAM = SerialParam(), quiet = TRUE)
  fit <- dream(vobj, form, info, BPPARAM = SerialParam())
  fit <- eBayes(fit)
})
tt <- topTable(fit, coef = "dayd10", number = Inf)
print(head(tt, 3))
cat("dream, genes with adj.P.Val < 0.05 for dayd10:", sum(tt$adj.P.Val < 0.05), "\n")
cat(sprintf("voomWithDreamWeights and dream took %.1f s\n", t3[["elapsed"]]))
stopifnot(sum(tt$adj.P.Val < 0.05) > 0, all(is.finite(tt$P.Value)))

# Kenward-Roger needs pbkrtest, so run it on a few genes
fit_kr <- dream(vobj[1:5, ], form, info, ddf = "Kenward-Roger", BPPARAM = SerialParam())
fit_kr <- eBayes(fit_kr)
cat("Kenward-Roger on 5 genes, residual df of the first gene:", fit_kr$df.residual[1], "\n")
stopifnot(all(is.finite(fit_kr$df.residual)))

cat(sprintf("\ntotal %.1f s\n", as.numeric(difftime(Sys.time(), started, units = "secs"))))
cat("DREAM_ENV_OK\n")
