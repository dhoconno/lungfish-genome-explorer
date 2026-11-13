# DESeq2 for GSE304256 (C6), each vaccine group's day 1 and day 2 against its day 0, run twice.
#
# Paper (STAR Methods, RNA sequencing): "DESeq2 was used for transcript normalization and
# differential expression analysis. Genes were considered significantly differentially
# expressed if the Benjamini-Hochberg adjusted p-value (fdr = 0.05) was below 0.05."
# Results, Fig. 6C: mRNA-LNP 1,078 up and 332 down on day 1, 316 and 47 on day 2; sam-MDNP
# 588 and 166 on day 1, 43 and 19 on day 2. Fig. 6D: RSAD2, IFIT2, ISG15, CMPK2, OASL and MX1
# up on day 1 in both groups. Classes (R2-STAT C6 claims 3 to 5): directional.
# Not stated: the design formula, an animal term, a prefilter, a fold-change bar, and whether
# days 4 and 7 sat in the fit. This script fits each group alone, with ~day and ~animal + day,
# on days 0 to 2 (the 30 files of the BULK-SUBSET ruling) or on all five days (the 50 files).
# No prefilter, no fold-change bar, results(alpha = 0.05). Column 2 (unstranded) is the count.
#
# Step A reads the deposited ReadsPerGene files. Step B is the same with the files of the runs
# aligned here replaced by our ReadsPerGene.out.tab. The two must agree.
#
# Usage: Rscript de.R DEPOSIT_DIR ENA.tsv NAMES.tsv OUT_PREFIX DAYS [STAR_DIR RUNS.tsv]
#   DEPOSIT_DIR   the files of GSE304256_RAW.tar, unpacked
#   ENA.tsv       ena_read_run_PRJNA1299784.tsv (sample_alias = GSM, sample_title has day and group)
#   NAMES.tsv     gene_id and gene_name from the Ensembl 100 GTF, no header
#   DAYS          d0-2 or all
#   STAR_DIR, RUNS.tsv   for step B: star/<run>/ReadsPerGene.out.tab and compare/runs.tsv
suppressPackageStartupMessages({ library(DESeq2); library(BiocParallel) })
args <- commandArgs(trailingOnly = TRUE)
ddir <- args[1]; out <- args[4]; days_set <- args[5]
step <- if (length(args) >= 7) "B" else "A"
register(MulticoreParam(as.integer(Sys.getenv("DE_THREADS", "4"))))
ena <- read.delim(args[2], check.names = FALSE)
nm <- read.delim(args[3], header = FALSE, col.names = c("id", "name"))

files <- list.files(ddir, pattern = "_ReadsPerGene\\.out\\.tab\\.gz$")
re <- "^(GSM[0-9]+)_p22167-s([0-9]+)_([A-Za-z0-9]+)-D([0-9]+)_ReadsPerGene\\.out\\.tab\\.gz$"
stopifnot(all(grepl(re, files)))
cd <- data.frame(file = files, gsm = sub(re, "\\1", files), animal = sub(re, "\\3", files),
  day = as.integer(sub(re, "\\4", files)))
t <- ena$sample_title[match(cd$gsm, ena$sample_alias)]
stopifnot(!anyNA(t))
cd$ena_day <- as.integer(sub(".*Day-([0-9]+).*", "\\1", t))
cd$group <- sub(".* ", "", t)
# Key check (R2-BIO C6 claim 5): the ENA day equals the file name's day, and each animal sits
# in one group with one file a day.
key_ok <- all(cd$ena_day == cd$day) && all(tapply(cd$group, cd$animal, function(x) length(unique(x))) == 1) &&
  !any(duplicated(cd[, c("animal", "day")]))
cat("step", step, "DESeq2", as.character(packageVersion("DESeq2")), "files", nrow(cd),
  "key_ok", key_ok, "\n")

read_rpg <- function(path) {
  x <- read.delim(path, header = FALSE)
  x[!startsWith(x$V1, "N_"), 1:2]
}
first <- read_rpg(file.path(ddir, cd$file[1]))
mat <- matrix(0L, nrow(first), nrow(cd), dimnames = list(first$V1, cd$gsm))
for (i in seq_len(nrow(cd))) {
  x <- read_rpg(file.path(ddir, cd$file[i])); stopifnot(identical(x$V1, first$V1))
  mat[, i] <- as.integer(x$V2)
}
swapped <- character(0)
if (step == "B") {
  runs <- read.delim(args[7])
  for (i in seq_len(nrow(runs))) {
    x <- read_rpg(file.path(args[6], runs$run[i], "ReadsPerGene.out.tab"))
    stopifnot(identical(x$V1, first$V1))
    mat[, runs$geo_sample[i]] <- as.integer(x$V2)
    swapped <- c(swapped, runs$geo_sample[i])
  }
}
cat("columns swapped in:", length(swapped), paste(swapped, collapse = ","), "\n")
keep_days <- if (days_set == "d0-2") c(0, 1, 2) else c(0, 1, 2, 4, 7)
sym <- setNames(nm$name, nm$id)[rownames(mat)]
isg <- c("RSAD2", "IFIT2", "ISG15", "CMPK2", "OASL", "MX1")
rows <- list()
add <- function(...) rows[[length(rows) + 1]] <<- data.frame(..., stringsAsFactors = FALSE)
add(step = step, days = days_set, group = "all", design = "none", contrast = "key",
  up = NA, down = NA, detail = paste("key_ok", key_ok, "files", nrow(cd)))
for (g in sort(unique(cd$group))) for (des in c("day", "animal_day")) {
  k <- cd$group == g & cd$day %in% keep_days
  sd <- cd[k, ]
  sd$day <- factor(paste0("D", sd$day), levels = paste0("D", keep_days))
  sd$animal <- factor(sd$animal)
  f <- if (des == "day") ~day else ~animal + day
  dds <- DESeqDataSetFromMatrix(mat[, k], sd, design = f)
  dds <- DESeq(dds, quiet = TRUE, parallel = TRUE)
  for (d in c("D1", "D2")) {
    res <- results(dds, contrast = c("day", d, "D0"), alpha = 0.05)
    ok <- !is.na(res$padj) & res$padj < 0.05
    gi <- match(isg, sym)
    det <- paste(sprintf("%s:%s:%s", isg,
      ifelse(is.na(gi), "absent", signif(res$log2FoldChange[gi], 3)),
      ifelse(is.na(gi), "NA", signif(res$padj[gi], 3))), collapse = " ")
    add(step = step, days = days_set, group = g, design = des, contrast = paste0(d, "_vs_D0"),
      up = sum(ok & res$log2FoldChange > 0), down = sum(ok & res$log2FoldChange < 0), detail = det)
    r <- as.data.frame(res); r$gene_id <- rownames(r)
    write.table(r, gzfile(sprintf("%s_%s_%s_%s_%s.tsv.gz", out, days_set, g, des, d)), sep = "\t",
      quote = FALSE, row.names = FALSE)
  }
}
tab <- do.call(rbind, rows)
write.table(tab, sprintf("%s_%s_results.tsv", out, days_set), sep = "\t", quote = FALSE, row.names = FALSE)
print(tab[, 1:7], row.names = FALSE)
