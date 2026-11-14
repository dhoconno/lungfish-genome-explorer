// RNASeqExportTemplates.swift - The DESeq2 template and the blocks both templates share (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The templates are text the export writes, not a resource. `deseq2.R` sets `alpha` in `results()` to the cutoff the person
// picks (`SCR/rulings/ADJ-BULK.md:82-85`), applies a bar to the MLE log2 fold change with padj beside it and reports a shrunken
// value only beside it (`ADJ-TAIL.md:11`), takes size factors from host rows only and keeps the not-host rows in the table.

import Foundation

public enum RNASeqExportTemplates {
    static func rString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func settingsBlock(_ s: RNASeqExportSettings) -> String {
        let terms = s.design.map(rString).joined(separator: ", ")
        let contrasts = s.contrasts.map { "c(\(rString($0.factor)), \(rString($0.numerator)), \(rString($0.denominator)))" }.joined(separator: ", ")
        return #"""
        # ---- Settings written by the export. Edit them here and run the script again. ----
        padj_cutoff <- \#(s.padjCutoff)   # the adjusted p-value cutoff you picked
        lfc_bar <- \#(s.lfcBar.map { "\($0)" } ?? "NULL")   # a bar on the MLE log2 fold change, NULL for none
        design_terms <- c(\#(terms))   # columns of samples.tsv in the model, the last one is the tested factor
        contrasts <- list(\#(contrasts))   # factor, numerator level, denominator level
        batch_column <- \#(s.batch.map(rString) ?? "NULL")
        batch_step <- "\#(s.batchCorrection.rawValue)"   # none, combat-seq or sva
        # ---- End of settings ----
        """#
    }

    /// Reads the folder's own files. The first column of counts.tsv and genes.tsv is the gene id.
    static let readBlock = #"""
    if (length(design_terms) == 0 || length(contrasts) == 0) {
      stop("This export was made without --design and --contrast. Run lungfish-cli rnaseq export again with them, or fill in the settings above.", call. = FALSE)
    }
    counts  <- as.matrix(read.delim("counts.tsv", row.names = 1, check.names = FALSE))
    genes   <- read.delim("genes.tsv", row.names = 1, check.names = FALSE, colClasses = "character")
    coldata <- read.delim("samples.tsv", check.names = FALSE, colClasses = "character")
    rownames(coldata) <- coldata$sample_id
    stopifnot(setequal(colnames(counts), rownames(coldata)))
    coldata <- coldata[colnames(counts), , drop = FALSE]
    for (term in unique(c(design_terms, batch_column))) coldata[[term]] <- factor(coldata[[term]])
    # Size factors and normalisation factors come from host rows only. Not-host rows stay in the table and in the results.
    not_host <- rownames(genes)[tolower(genes$not_host) %in% "true"]
    host <- !(rownames(counts) %in% not_host)
    """#

    /// The check both templates run before a batch step, as the export ran it in Swift.
    static let checkBlock = #"""
    check_batch_design <- function(coldata, design_terms, batch_column, step) {
      batch <- as.character(coldata[[batch_column]])
      if (anyNA(batch) || any(batch == "") || length(unique(batch)) < 2) {
        stop(step, " needs a batch column with two or more batches and no empty cell, and ", batch_column, " has not.", call. = FALSE)
      }
      for (term in setdiff(design_terms, batch_column)) {
        level <- as.character(coldata[[term]])
        found <- character()
        for (b in sort(unique(batch))) {
          inside <- sort(unique(level[batch == b]))
          whole <- inside[vapply(inside, function(l) all(batch[level == l] == b), logical(1))]
          if (length(inside) == 1) found <- c(found, sprintf("The batch %s holds only samples of the level %s of %s", b, inside, term))
          else if (identical(whole, inside)) found <- c(found, sprintf("The batch %s holds exactly the levels %s of %s and every sample of them", b, paste(inside, collapse = ", "), term))
        }
        mm <- model.matrix(~ b + f, data.frame(b = factor(batch), f = factor(level)))
        if (!length(found) && qr(mm)$rank < ncol(mm)) found <- sprintf("The batch and %s overlap so that no model can separate them", term)
        if (length(found)) {
          stop(step, " cannot run on the batch column ", batch_column, " with the design ~ ", batch_column, " + ", paste(design_terms, collapse = " + "), ". ",
               paste(found, collapse = ". "), ". So the model loses full rank, and the batch cannot be told apart from those levels of ", term,
               ". Use a batch that crosses the levels of ", term, ", or set batch_step to \"none\".", call. = FALSE)
        }
      }
    }
    """#

    public static func deseq2(_ s: RNASeqExportSettings) -> String {
        let batch = s.batchCorrection == .none ? "" : """
        \(checkBlock)
        check_batch_design(coldata, design_terms, batch_column, batch_step)
        suppressPackageStartupMessages(library(sva))
        model_terms <- design_terms
        if (batch_step == "combat-seq") {
          counts <- round(ComBat_seq(counts, batch = coldata[[batch_column]], group = coldata[[design_terms[length(design_terms)]]]))
          storage.mode(counts) <- "integer"
        } else {
          # sva: surrogate variables with the design as the full model and the batch as the null model.
          norm <- counts(estimateSizeFactors(DESeqDataSetFromMatrix(counts, coldata, ~ 1), controlGenes = which(host)), normalized = TRUE)
          norm <- norm[rowMeans(norm) > 1, , drop = FALSE]
          mod  <- model.matrix(as.formula(paste("~", paste(c(batch_column, design_terms), collapse = " + "))), coldata)
          mod0 <- model.matrix(as.formula(paste("~", batch_column)), coldata)
          sv <- svaseq(norm, mod, mod0, n.sv = num.sv(norm, mod, method = "be"))$sv
          for (i in seq_len(ncol(sv))) coldata[[paste0("SV", i)]] <- sv[, i]
          model_terms <- c(batch_column, colnames(coldata)[grepl("^SV[0-9]+$", colnames(coldata))], design_terms)
        }

        """
        return """
        # deseq2.R - written by lungfish-cli rnaseq export. Run it in this folder with Rscript --vanilla deseq2.R
        # Needs DESeq2, and sva for a batch step.
        suppressPackageStartupMessages(library(DESeq2))
        \(settingsBlock(s))
        \(readBlock)
        model_terms <- design_terms
        # Estimated counts (salmon's NumReads) are fractional, so they are rounded to whole counts here, as DESeq2 needs,
        # the same step as scripts/repro/rnaseq/gse162164/de.R. Reads, pairs and UMI counts are whole already.
        counts <- round(counts)
        storage.mode(counts) <- "integer"
        \(batch)dds <- DESeqDataSetFromMatrix(counts, coldata, as.formula(paste("~", paste(unique(model_terms), collapse = " + "))))
        dds <- estimateSizeFactors(dds, controlGenes = which(host))
        dds <- DESeq(dds, quiet = TRUE)
        dir.create("deseq2-results", showWarnings = FALSE)
        write.table(data.frame(sample_id = colnames(dds), size_factor = sizeFactors(dds)), "deseq2-results/size_factors.tsv", sep = "\\t", quote = FALSE, row.names = FALSE)
        shrink_type <- if (requireNamespace("ashr", quietly = TRUE)) "ashr" else "normal"
        for (cn in contrasts) {
          res <- results(dds, contrast = cn, alpha = padj_cutoff)
          shrunk <- tryCatch(lfcShrink(dds, contrast = cn, res = res, type = shrink_type, quiet = TRUE), error = function(e) NULL)
          table <- data.frame(gene_id = rownames(res), as.data.frame(res), check.names = FALSE)
          # The shrunken value sits beside the MLE value and never decides which genes pass.
          table$log2FoldChange_shrunk <- if (is.null(shrunk)) NA_real_ else shrunk$log2FoldChange
          table$not_host <- !host
          deg <- !is.na(table$padj) & table$padj < padj_cutoff
          if (!is.null(lfc_bar)) deg <- deg & abs(table$log2FoldChange) >= lfc_bar
          table$deg <- deg
          name <- paste(cn, collapse = "_")
          write.table(table, sprintf("deseq2-results/%s.tsv", name), sep = "\\t", quote = FALSE, row.names = FALSE)
          cat(sprintf("%s: %d genes pass padj < %s%s, %d up and %d down, alpha %s, %d genes tested\\n", name, sum(deg), padj_cutoff,
                      if (is.null(lfc_bar)) "" else paste0(" and |log2 fold change| >= ", lfc_bar),
                      sum(deg & table$log2FoldChange > 0), sum(deg & table$log2FoldChange < 0), metadata(res)$alpha, sum(!is.na(table$padj))))
        }

        """
    }
}
