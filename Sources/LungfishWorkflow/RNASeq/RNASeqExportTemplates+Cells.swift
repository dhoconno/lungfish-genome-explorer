// RNASeqExportTemplates+Cells.swift - seurat.R of a single-cell export (Phase 5.2 lane RS-SC-HANDOFF, slice B)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Text the export writes, not a resource. Each matrix is read with Matrix::readMM from the file LGE kept as given, plain or gzip,
// and the table of cells is written before Seurat is called, so an R without Seurat stops in words after the table.
// The Seurat object takes orig.ident and its identity from the sample of each cell and not from its name (Phase 5.5 lane CM-IDENT).

import Foundation

extension RNASeqExportTemplates {
    static func seurat() -> String { seuratRead + "\n" + seuratObject + "\n" }

    private static let seuratRead = #"""
# seurat.R - written by lungfish-cli rnaseq export. Run it in this folder with Rscript --vanilla seurat.R
# Needs Matrix, and Seurat for the last step. The table of cells is written before Seurat is called.
# Checked on Seurat 5.5.1 from conda-forge (SeuratObject 5.4.0, R 4.5.3). No other Seurat version is checked.
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
# The object holds every feature type in its RNA assay, so Antibody Capture rows count in nCount_RNA. Subset by type before normalising.
cat(sprintf("features %d, of them %d not %s\n", nrow(combined), sum(info$type != feature_type), feature_type))
if (requireNamespace("Seurat", quietly = TRUE)) {
  # Seurat reads orig.ident and the identity of a cell from the part of its name before the first "_", so cov_10_AAAC and cov_11_AAAC
  # would both be "cov". The sample of each cell is set here instead, as a factor with its levels in the order of samples.tsv, since
  # factor() alone sorts them by the locale of the session. The barcode stays in meta.data, so a table written from the object keeps
  # the pair (sample, barcode) when Seurat renames the cells.
  sample_of <- factor(cells$sample, levels = samples$sample_id)
  object <- Seurat::CreateSeuratObject(counts = combined, project = "lungfish",
                                       meta.data = data.frame(orig.ident = sample_of, sample = cells$sample, barcode = cells$barcode, row.names = cells$cell))
  Seurat::Idents(object) <- "orig.ident"
  # Seurat writes "-" for "_" in a feature name and takes feature data only as a vector named by its own names, so match by position.
  features <- rownames(object[["RNA"]])
  if (length(features) != length(ids)) stop("Seurat kept ", length(features), " of the ", length(ids), " features, so the feature data cannot be matched by position.", call. = FALSE)
  object[["RNA"]][["name"]] <- stats::setNames(info$name, features)
  object[["RNA"]][["type"]] <- stats::setNames(info$type, features)
  object[["RNA"]][["not_host"]] <- stats::setNames(ids %in% not_host, features)
  print(object)
} else {
  stop("Seurat is not installed in this R, so the table of cells is written and no Seurat object is made. Install Seurat and run seurat.R again.", call. = FALSE)
}

# ---- Add your analysis here, such as NormalizeData, FindVariableFeatures, ScaleData, RunPCA, FindNeighbors, FindClusters and RunUMAP. ----

# ---- Hand back to LGE. LGE reads no RDS, so this block writes lge-cell-map.tsv, a table that lungfish-cli rnaseq cell-map import reads. ----
# The sample and barcode of each cell come from meta.data, never from its name, which the sample prefix and Seurat's renames change.
# Each reduction that gives every cell 2 or more finite values is written as <name>_1 to <name>_<k>, and one that does not is named in a line that says so. The numbers are written so LGE reads them back exactly, and seurat_clusters, when the object has it, is written as the labels.
write_lge_cell_map <- function(object, path = "lge-cell-map.tsv") {
  meta <- object[[]]
  for (column in c("sample", "barcode")) if (!column %in% names(meta)) stop("meta.data has no ", column, " column, so LGE cannot match the cells. Make the object with seurat.R, which sets sample and barcode.", call. = FALSE)
  table <- data.frame(sample = as.character(meta[["sample"]]), barcode = as.character(meta[["barcode"]]), stringsAsFactors = FALSE)
  methods <- c("umap" = "UMAP", "tsne" = "t-SNE", "pca" = "PCA")
  written <- character(); flags <- character()
  for (name in SeuratObject::Reductions(object)) {
    values <- SeuratObject::Embeddings(object, reduction = name)
    at <- match(rownames(meta), rownames(values))
    if (anyNA(at) || ncol(values) < 2 || !all(is.finite(values[at, ]))) {
      cat(sprintf("The reduction %s is left out of %s, since it does not give every cell of the object 2 or more finite values.\n", name, path))
      next
    }
    for (k in seq_len(ncol(values))) table[[paste0(name, "_", k)]] <- sprintf("%.17g", values[at, k])
    written <- c(written, name)
    if (name %in% names(methods)) flags <- c(flags, "--method", paste0(name, "=", methods[[name]]))
  }
  if (length(written) == 0) stop("No reduction of the object gives every cell 2 or more finite values, so ", path, " is not written. Run RunUMAP or RunPCA first.", call. = FALSE)
  labels <- intersect("seurat_clusters", names(meta))
  for (label in labels) {
    x <- as.character(meta[[label]]); x[is.na(x)] <- ""
    if (any(grepl("[\t\r\n]", x))) stop("A label of ", label, " holds a tab or a line break, which a table cannot hold. Rename it and run write_lge_cell_map again.", call. = FALSE)
    table[[label]] <- x
    flags <- c("--label-column", label, flags)
  }
  write.table(table, path, sep = "\t", quote = FALSE, row.names = FALSE, na = "", eol = "\n")
  cat(sprintf("Wrote %s, %d cells with the embeddings %s%s.\n", path, nrow(table), paste(written, collapse = ", "),
              if (length(labels)) paste0(" and the labels of ", paste(labels, collapse = ", ")) else ""))
  cat("Import it into LGE with this command, where RESULT is the single-cell result this folder was exported from and NEW names the new cell map, such as <project>/Analyses/<name>.lungfishrnaseq:\n")
  cat(paste(c("lungfish-cli rnaseq cell-map import RESULT --coordinates", shQuote(normalizePath(path)), flags, "--output NEW.lungfishrnaseq"), collapse = " "), "\n", sep = "")
  invisible(path)
}
if (length(SeuratObject::Reductions(object)) > 0) {
  write_lge_cell_map(object)
} else {
  cat("The object holds no reduction yet. After your analysis, such as RunPCA, FindClusters and RunUMAP, run write_lge_cell_map(object) to write lge-cell-map.tsv for lungfish-cli rnaseq cell-map import.\n")
}
"""#
}
