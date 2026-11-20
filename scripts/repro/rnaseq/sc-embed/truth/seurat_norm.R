#!/usr/bin/env Rscript
# Seurat 5.5.1 NormalizeData(normalization.method = "LogNormalize", scale.factor = 1e4) on the matrices that truth.py lists.
#
# Usage: Rscript --vanilla seurat_norm.R <jobs.tsv> <out folder> <source.txt>
#
# A job names a matrix file, its features file and a mode. `ge` keeps the Gene Expression rows, which is what 5.5 G1
# normalises. `all` keeps every row, as an object that is not subset by type holds them (BIO F14). Cells and features
# are named by position, so no name is changed (Seurat turns _ into - in a feature name). For each job the script
# runs the call on a Seurat object, runs it again on the bare matrix, and writes the `data` layer of the object as a
# dgCMatrix. <job>.i and <job>.p are int32 and <job>.x is double, all little-endian, and <job>.info holds the other
# facts. source.txt holds the versions and the installed R source of the functions that make the values.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3) stop("usage: seurat_norm.R <jobs.tsv> <out folder> <source.txt>")
suppressPackageStartupMessages({
  library(Matrix)
  library(Seurat)
  library(SeuratObject)
})
seurat_version <- as.character(packageVersion("Seurat"))
if (seurat_version != "5.5.1") stop(paste("Seurat", seurat_version, "is loaded, and this truth is for 5.5.1"))

ns <- asNamespace("Seurat")
text <- c(paste("Seurat", seurat_version), paste("SeuratObject", as.character(packageVersion("SeuratObject"))),
          paste("Matrix", as.character(packageVersion("Matrix"))), R.version.string, "")
for (name in c("NormalizeData.default", ".SparseNormalize", "LogNormalize", "LogNormalize.default",
               "LogNormalize.V3Matrix", "LogNorm")) {
  if (exists(name, envir = ns, inherits = FALSE)) {
    text <- c(text, paste0("Seurat:::", name), deparse(get(name, envir = ns)), "")
  } else {
    text <- c(text, paste0("Seurat:::", name, " is not defined in ", seurat_version), "")
  }
}
writeLines(text, args[3])

jobs <- read.delim(args[1], header = TRUE, quote = "", colClasses = "character", stringsAsFactors = FALSE)
dir.create(args[2], showWarnings = FALSE, recursive = TRUE)
write_bin <- function(path, x, size) {
  con <- file(path, "wb")
  writeBin(x, con, size = size, endian = "little")
  close(con)
}
for (k in seq_len(nrow(jobs))) {
  job <- jobs$job[k]
  m <- as(readMM(jobs$matrix[k]), "CsparseMatrix")
  features <- read.delim(jobs$features[k], header = FALSE, quote = "", colClasses = "character",
                         na.strings = character(), stringsAsFactors = FALSE)
  if (nrow(features) != nrow(m)) stop(paste(job, "has", nrow(features), "features and", nrow(m), "matrix rows"))
  type <- if (ncol(features) >= 3) features[[3]] else rep("Gene Expression", nrow(features))
  keep <- if (jobs$mode[k] == "ge") type == "Gene Expression" else rep(TRUE, length(type))
  m <- m[keep, , drop = FALSE]
  rownames(m) <- paste0("f", seq_len(nrow(m)))
  colnames(m) <- paste0("c", seq_len(ncol(m)))
  object <- CreateSeuratObject(counts = m, min.cells = 0, min.features = 0)
  object <- NormalizeData(object, normalization.method = "LogNormalize", scale.factor = 1e4, verbose = FALSE)
  d <- as(GetAssayData(object, layer = "data"), "CsparseMatrix")
  d2 <- as(NormalizeData(m, normalization.method = "LogNormalize", scale.factor = 1e4, verbose = FALSE), "CsparseMatrix")
  same <- identical(d@i, d2@i) && identical(d@p, d2@p) && identical(d@x, d2@x)
  # NormalizeData on a dgCMatrix takes .SparseNormalize, which is plain R. LogNorm is the compiled routine that
  # LogNormalize.V3Matrix calls, and the installed package holds no C++ source for it, so run it and compare its output.
  logn <- tryCatch(as(Seurat:::LogNorm(m, scale_factor = 1e4, display_progress = FALSE), "CsparseMatrix"),
                   error = function(e) NULL)
  compiled <- if (is.null(logn)) "ERROR" else toupper(as.character(
    identical(logn@i, d@i) && identical(logn@p, d@p) && identical(logn@x, d@x)))
  stem <- file.path(args[2], job)
  write_bin(paste0(stem, ".i"), as.integer(d@i), 4L)
  write_bin(paste0(stem, ".p"), as.integer(d@p), 4L)
  write_bin(paste0(stem, ".x"), as.numeric(d@x), 8L)
  writeLines(c(paste("rows", nrow(d)), paste("cols", ncol(d)), paste("identical", toupper(as.character(same))),
               paste("compiled_lognorm_identical", compiled), paste("class", class(d)[1]), paste("seurat", seurat_version)), paste0(stem, ".info"))
  message(job, ": ", nrow(d), " rows, ", ncol(d), " cells, ", length(d@x), " entries, object and matrix calls identical ", same)
}
