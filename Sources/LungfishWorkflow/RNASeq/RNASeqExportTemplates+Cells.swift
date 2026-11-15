// RNASeqExportTemplates+Cells.swift - seurat.R of a single-cell export (Phase 5.2 lane RS-SC-HANDOFF, slice B)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Text the export writes, not a resource. Each matrix is read with Matrix::readMM from the file LGE kept as given, plain or gzip,
// and the table of cells is written before Seurat is called, so an R without Seurat stops in words after the table.

import Foundation

extension RNASeqExportTemplates {
    static func seurat() -> String { seuratRead + "\n" + seuratObject + "\n" }

    private static let seuratRead = #"""
# seurat.R - written by lungfish-cli rnaseq export. Run it in this folder with Rscript --vanilla seurat.R
# Needs Matrix, and Seurat for the last step. The table of cells is written before Seurat is called.
suppressPackageStartupMessages(library(Matrix))
# ---- Settings written by the export. Edit them here and run the script again. ----
feature_type <- "Gene Expression"   # the feature type counted in the umis and genes of the table of cells
# ---- End of settings ----
read_table <- function(path) read.delim(path, colClasses = "character", check.names = FALSE, quote = "", comment.char = "", na.strings = character())
samples <- read_table("samples.tsv")
genes <- read_table("genes.tsv")
not_host <- genes$gene_id[tolower(genes$not_host) %in% "true"]
with_gz <- function(path, read) { con <- gzfile(path, "rt"); on.exit(close(con)); read(con) }
lines_of <- function(path) { x <- with_gz(path, function(con) readLines(con, warn = FALSE)); strsplit(x[nzchar(x)], "\t", fixed = TRUE) }
find_file <- function(dir, stems) {
  for (stem in stems) for (ext in c("", ".gz")) if (file.exists(file.path(dir, paste0(stem, ext)))) return(file.path(dir, paste0(stem, ext)))
  stop(dir, " holds none of ", paste0(stems, "(.gz)", collapse = " or "), ".", call. = FALSE)
}
column <- function(rows, n, otherwise) vapply(rows, function(f) if (length(f) >= n) f[n] else otherwise, "")
counts <- list(); tables <- list(); ids <- NULL; info <- NULL
for (i in seq_len(nrow(samples))) {
  sample <- samples$sample_id[i]; dir <- samples$folder[i]
  m <- with_gz(find_file(dir, "matrix.mtx"), function(con) methods::as(Matrix::readMM(con), "CsparseMatrix"))
  rows <- lines_of(find_file(dir, c("features.tsv", "genes.tsv")))
  barcodes <- column(lines_of(find_file(dir, "barcodes.tsv")), 1, "")
  if (nrow(m) != length(rows)) stop(sample, ": the matrix has ", nrow(m), " rows and its features file lists ", length(rows), " features.", call. = FALSE)
  if (ncol(m) != length(barcodes)) stop(sample, ": the matrix has ", ncol(m), " columns and its barcodes file lists ", length(barcodes), " barcodes.", call. = FALSE)
  id <- column(rows, 1, ""); type <- column(rows, 3, "Gene Expression")
  if (is.null(ids)) { ids <- id; info <- data.frame(name = column(rows, 2, ""), type = type) }
  else if (!identical(ids, id)) stop(sample, " lists other features than the samples before it, so one object cannot hold them.", call. = FALSE)
  expression <- m[type == feature_type, , drop = FALSE]
  cell <- if (nrow(samples) > 1) paste0(sample, "_", barcodes) else barcodes
  colnames(m) <- cell
  counts[[i]] <- m
  tables[[i]] <- data.frame(cell = cell, sample = sample, barcode = barcodes, umis = as.integer(round(Matrix::colSums(expression))),
                            genes = as.integer(Matrix::colSums(expression > 0)), stringsAsFactors = FALSE)
}
"""#

    private static let seuratObject = #"""
combined <- do.call(cbind, counts)
rownames(combined) <- ids
cells <- do.call(rbind, tables)
write.table(cells, "seurat-cells.tsv", sep = "\t", quote = FALSE, row.names = FALSE)
for (i in seq_len(nrow(samples))) cat(sprintf("cells %s %d\n", samples$sample_id[i], nrow(tables[[i]])))
cat(sprintf("cells total %d\n", nrow(cells)))
cat(sprintf("not-host features %d\n", length(not_host)))
if (requireNamespace("Seurat", quietly = TRUE)) {
  object <- Seurat::CreateSeuratObject(counts = combined, project = "lungfish", meta.data = data.frame(sample = cells$sample, row.names = cells$cell))
  object[["RNA"]][["name"]] <- info$name
  object[["RNA"]][["type"]] <- info$type
  object[["RNA"]][["not_host"]] <- ids %in% not_host
  print(object)
} else {
  stop("Seurat is not installed in this R, so the table of cells is written and no Seurat object is made. Install Seurat and run seurat.R again.", call. = FALSE)
}
"""#
}
