# Aggregate salmon transcript estimates to genes with tximport.
# Usage: Rscript --vanilla gene.R <quant_dir> <samples.tsv> <tx2gene.tsv> <out_dir>
# samples.tsv has columns run, sample, library (one row a run); quant_dir/<run>/quant.sf.
# Writes gene_counts.tsv (estimated counts, countsFromAbundance "no"), gene_tpm.tsv,
# gene_length.tsv (average transcript length), gene_counts_lstpm.tsv (lengthScaledTPM)
# and a run_info.tsv with salmon's mapping rate and detected library type.
suppressPackageStartupMessages({ library(tximport); library(jsonlite) })
a <- commandArgs(trailingOnly = TRUE)
qdir <- a[1]; sheet <- read.delim(a[2], colClasses = "character")
t2g <- read.delim(a[3], colClasses = "character")[, c("transcript_id", "gene_id")]
out <- a[4]; dir.create(out, showWarnings = FALSE, recursive = TRUE)
sheet <- sheet[file.exists(file.path(qdir, sheet$run, "quant.sf")), ]
sheet <- sheet[order(sheet$sample, as.integer(sheet$library)), ]
lab <- paste0(sheet$sample, "_", sheet$library)
files <- setNames(file.path(qdir, sheet$run, "quant.sf"), lab)
txi <- tximport(files, type = "salmon", tx2gene = t2g, countsFromAbundance = "no")
ls <- tximport(files, type = "salmon", tx2gene = t2g, countsFromAbundance = "lengthScaledTPM")
w <- function(m, f) {
  d <- data.frame(gene_id = rownames(m), round(m, 4), check.names = FALSE)
  write.table(d, file.path(out, f), sep = "\t", quote = FALSE, row.names = FALSE)
}
w(txi$counts, "gene_counts.tsv"); w(txi$abundance, "gene_tpm.tsv")
w(txi$length, "gene_length.tsv"); w(ls$counts, "gene_counts_lstpm.tsv")
info <- do.call(rbind, lapply(seq_len(nrow(sheet)), function(i) {
  m <- fromJSON(file.path(qdir, sheet$run[i], "aux_info", "meta_info.json"))
  lf <- file.path(qdir, sheet$run[i], "lib_format_counts.json")
  lt <- if (file.exists(lf)) fromJSON(lf)$expected_format else NA
  data.frame(label = lab[i], run = sheet$run[i], sample = sheet$sample[i],
             library = sheet$library[i], num_processed = m$num_processed,
             num_mapped = m$num_mapped, percent_mapped = m$percent_mapped,
             num_decoy_fragments = if (is.null(m$num_decoy_fragments)) NA else m$num_decoy_fragments,
             library_types = paste(m$library_types, collapse = ","), expected_format = lt)
}))
write.table(info, file.path(out, "run_info.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
cat(nrow(txi$counts), "genes x", ncol(txi$counts), "runs\n")
