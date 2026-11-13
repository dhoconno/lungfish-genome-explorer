# The two expression claims of GSE152418 (C2) on the bulk PBMC counts, run twice.
#
# Paper (Arunachalam et al. 2020, Science 369:1210, Results): the ISG signature of 33 genes
# from the CITE-seq data is strongly induced in COVID-19 subjects against healthy donors
# (Fig. 4G), and no expression of genes encoding IFN-alpha or IFN-beta is detected.
# Classes (R2-STAT C2 claims 2 and 3): directional.
#
# Step A reads the deposited 60,683 x 34 matrix. Step B is the same matrix with the columns of
# the samples aligned here replaced by the sum of their two runs in ReadsPerGene column 2.
# The two steps must give the same result, which isolates what our quantification changed.
#
# The 33 ISGs are drawn in Fig. 4C and 4G and listed in the supplement, which is not on the
# drive (R2-STAT note 9). This script scores a stand-in set, the three ISGs the Results name
# in the text (IFI27, IFITM3, ISG15), and says so in every output.
#
# Usage: Rscript de.R DEPOSIT.txt.gz SAMPLES.tsv NAMES.tsv OUT_PREFIX [STAR_DIR COMPARE_SAMPLES.tsv]
#   SAMPLES.tsv           studies/GSE152418/samples.tsv (geo_title, condition, time_point, donor)
#   NAMES.tsv             gene_id and gene_name from the Ensembl 100 GTF, no header
#   STAR_DIR, COMPARE_SAMPLES.tsv   given for step B: star/<run>/ReadsPerGene.out.tab and
#                         compare/samples.tsv (sample, runs, verdict) from compare.py
suppressPackageStartupMessages(library(DESeq2))
args <- commandArgs(trailingOnly = TRUE)
dep <- read.delim(gzfile(args[1]), check.names = FALSE)
s <- read.delim(args[2], check.names = FALSE)
nm <- read.delim(args[3], header = FALSE, col.names = c("id", "name"))
out <- args[4]
step <- if (length(args) >= 6) "B" else "A"
mat <- as.matrix(dep[, -1]); rownames(mat) <- dep[[1]]; storage.mode(mat) <- "integer"
swapped <- character(0)
if (step == "B") {
  cs <- read.delim(args[6])
  for (i in seq_len(nrow(cs))) {
    runs <- strsplit(cs$runs[i], ",")[[1]]
    v <- 0
    for (r in runs) {
      t <- read.delim(file.path(args[5], r, "ReadsPerGene.out.tab"), header = FALSE)
      t <- t[!startsWith(t$V1, "N_"), ]
      stopifnot(identical(t$V1, rownames(mat)))
      v <- v + t$V2
    }
    mat[, cs$sample[i]] <- as.integer(v)
    swapped <- c(swapped, cs$sample[i])
  }
}
cat("step", step, "DESeq2", as.character(packageVersion("DESeq2")), "columns swapped in:",
  length(swapped), paste(swapped, collapse = ","), "\n")

key <- unique(s[, c("geo_title", "condition", "time_point", "animal_or_donor")])
key <- key[match(colnames(mat), key$geo_title), ]
stopifnot(!anyNA(key$geo_title))
cd <- data.frame(sample = key$geo_title, donor = key$animal_or_donor,
  covid = ifelse(key$condition == "Healthy", "Healthy", "COVID"),
  day = suppressWarnings(as.integer(sub(" days.*", "", key$time_point))),
  convalescent = key$condition == "Convalescent")
cd$covid <- factor(cd$covid, levels = c("Healthy", "COVID"))
# One sample a patient: each COVID-19 patient's earliest draw, the convalescent sample out.
acute <- cd[cd$covid == "COVID" & !cd$convalescent, ]
first <- acute[order(acute$donor, acute$day), ]
first <- first[!duplicated(first$donor), "sample"]
sets <- list(all34 = cd$sample, one_per_patient = c(first, cd$sample[cd$covid == "Healthy"]))

sym <- setNames(nm$name, nm$id)[rownames(mat)]
lib <- colSums(mat)
cpm <- t(t(mat) / lib) * 1e6
rows <- list()
add <- function(...) rows[[length(rows) + 1]] <<- data.frame(..., stringsAsFactors = FALSE)

# Claim: no IFN-alpha or IFN-beta transcripts, read as under 1 CPM in every sample.
ifn <- which(grepl("^IFNA[0-9]+$", sym) | sym %in% c("IFNB1"))
for (g in ifn) add(step = step, test = "ifn_ab_cpm", set = "all34", gene = sym[g],
  stat = "max_cpm", value = signif(max(cpm[g, ]), 4), n = sum(mat[g, ] > 0), p = NA)

# Claim: the ISG stand-in score is higher in COVID-19 than in healthy donors.
isg <- c("IFI27", "IFITM3", "ISG15")
gi <- match(isg, sym); stopifnot(!anyNA(gi))
for (nmset in names(sets)) {
  keep <- cd$sample %in% sets[[nmset]]
  lc <- log2(cpm[gi, keep, drop = FALSE] + 1)
  score <- colMeans((lc - rowMeans(lc)) / apply(lc, 1, sd))
  grp <- cd$covid[keep]
  w <- wilcox.test(score[grp == "COVID"], score[grp == "Healthy"], exact = FALSE)
  add(step = step, test = "isg_score", set = nmset, gene = paste(isg, collapse = "+"),
    stat = "median_COVID_minus_median_Healthy",
    value = signif(median(score[grp == "COVID"]) - median(score[grp == "Healthy"]), 4),
    n = sum(keep), p = signif(w$p.value, 4))
  dds <- DESeqDataSetFromMatrix(mat[, keep], cd[keep, ], design = ~covid)
  dds <- DESeq(dds, quiet = TRUE)
  res <- results(dds, contrast = c("covid", "COVID", "Healthy"), alpha = 0.05)
  for (g in gi) add(step = step, test = "deseq2_isg", set = nmset, gene = sym[g],
    stat = "log2FC", value = signif(res$log2FoldChange[g], 4), n = sum(keep),
    p = signif(res$padj[g], 4))
  ok <- !is.na(res$padj) & res$padj < 0.05
  add(step = step, test = "deseq2_total", set = nmset, gene = "all",
    stat = "up/down at padj<0.05", value = paste0(sum(ok & res$log2FoldChange > 0), "/",
      sum(ok & res$log2FoldChange < 0)), n = sum(keep), p = NA)
  r <- as.data.frame(res); r$gene_id <- rownames(r)
  write.table(r, gzfile(paste0(out, "_deseq2_", nmset, ".tsv.gz")), sep = "\t", quote = FALSE,
    row.names = FALSE)
}
tab <- do.call(rbind, rows)
write.table(tab, paste0(out, "_results.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
print(tab, row.names = FALSE)
