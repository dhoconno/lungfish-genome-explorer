// RNASeqExportTemplates+EdgeR.swift - The edgeR, limma voom and dream template (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Library sizes and normalisation factors come from host rows only, and the not-host rows stay in the table and in the
// results. The dream part runs only when `variancePartition` is installed and otherwise stops in words, after edgeR and limma
// have written their results. The design check runs again before the batch step, as in `deseq2.R`.

import Foundation

extension RNASeqExportTemplates {
    public static func edgerLimmaDream(_ s: RNASeqExportSettings) -> String {
        let batch = s.batchCorrection == .none ? "" : """
        \(checkBlock)
        check_batch_design(coldata, design_terms, batch_column, batch_step)
        suppressPackageStartupMessages(library(sva))
        if (batch_step == "combat-seq") {
          counts <- ComBat_seq(counts, batch = coldata[[batch_column]], group = coldata[[design_terms[length(design_terms)]]])
        } else {
          # sva: surrogate variables with the design as the full model and the batch as the null model.
          norm <- cpm(counts[host, , drop = FALSE], log = FALSE)
          norm <- norm[rowMeans(norm) > 1, , drop = FALSE]
          mod  <- model.matrix(as.formula(paste("~", paste(c(batch_column, design_terms), collapse = " + "))), coldata)
          mod0 <- model.matrix(as.formula(paste("~", batch_column)), coldata)
          sv <- svaseq(norm, mod, mod0, n.sv = num.sv(norm, mod, method = "be"))$sv
          for (i in seq_len(ncol(sv))) coldata[[paste0("SV", i)]] <- sv[, i]
          model_terms <- c(batch_column, colnames(coldata)[grepl("^SV[0-9]+$", colnames(coldata))], design_terms)
        }

        """
        return """
        # edger-limma-dream.R - written by lungfish-cli rnaseq export. Run it in this folder with Rscript --vanilla edger-limma-dream.R
        # Needs edgeR and limma, sva for a batch step, and variancePartition for the dream part.
        suppressPackageStartupMessages({ library(edgeR); library(limma) })
        \(settingsBlock(s))
        random_terms <- character()   # columns of samples.tsv fitted as random intercepts by dream, such as the animal
        \(readBlock)
        model_terms <- design_terms
        \(batch)dir.create("edger-limma-dream-results", showWarnings = FALSE)
        y <- DGEList(counts)
        # Library sizes and normalisation factors come from the host rows only, and every row stays in the table.
        host_y <- calcNormFactors(DGEList(counts[host, , drop = FALSE]))
        y$samples$lib.size <- host_y$samples$lib.size
        y$samples$norm.factors <- host_y$samples$norm.factors
        keep <- filterByExpr(y, group = coldata[[design_terms[length(design_terms)]]]) | !host
        design_formula <- as.formula(paste("~", paste(unique(model_terms), collapse = " + ")))
        report <- function(table, name, p, lfc) {
          deg <- !is.na(table[[p]]) & table[[p]] < padj_cutoff
          if (!is.null(lfc_bar)) deg <- deg & abs(table[[lfc]]) >= lfc_bar
          table$deg <- deg
          write.table(table, sprintf("edger-limma-dream-results/%s.tsv", name), sep = "\\t", quote = FALSE, row.names = FALSE)
          cat(sprintf("%s: %d genes pass %s < %s, %d up and %d down\\n", name, sum(deg), p, padj_cutoff, sum(deg & table[[lfc]] > 0), sum(deg & table[[lfc]] < 0)))
        }
        for (cn in contrasts) {
          cd <- coldata
          cd[[cn[1]]] <- relevel(factor(cd[[cn[1]]]), ref = cn[3])
          design <- model.matrix(design_formula, cd)
          coef <- paste0(cn[1], cn[2])
          name <- paste(cn, collapse = "_")
          yk <- y[keep, , keep.lib.sizes = TRUE]
          yk <- estimateDisp(yk, design)
          qlf <- glmQLFTest(glmQLFit(yk, design), coef = coef)
          tt <- topTags(qlf, n = Inf, sort.by = "none")$table
          report(data.frame(gene_id = rownames(tt), tt, not_host = !host[keep], check.names = FALSE), paste0("edger_", name), "FDR", "logFC")
          v <- voom(yk, design)
          tv <- topTable(eBayes(lmFit(v, design)), coef = coef, number = Inf, sort.by = "none")
          report(data.frame(gene_id = rownames(tv), tv, not_host = !host[keep], check.names = FALSE), paste0("limma_voom_", name), "adj.P.Val", "logFC")
        }
        if (!requireNamespace("variancePartition", quietly = TRUE)) {
          stop("variancePartition is not installed, so the dream part cannot run. The edgeR and limma results are in edger-limma-dream-results. ",
               "Install variancePartition from Bioconductor and run this script again.", call. = FALSE)
        }
        suppressPackageStartupMessages(library(variancePartition))
        dream_formula <- as.formula(paste("~", paste(c(unique(model_terms), paste0("(1|", random_terms, ")")), collapse = " + ")))
        for (cn in contrasts) {
          cd <- coldata
          cd[[cn[1]]] <- relevel(factor(cd[[cn[1]]]), ref = cn[3])
          yk <- y[keep, , keep.lib.sizes = TRUE]
          vobj <- voomWithDreamWeights(yk, dream_formula, cd)
          fit <- eBayes(dream(vobj, dream_formula, cd))
          td <- topTable(fit, coef = paste0(cn[1], cn[2]), number = Inf, sort.by = "none")
          report(data.frame(gene_id = rownames(td), td, not_host = !host[keep], check.names = FALSE), paste0("dream_", paste(cn, collapse = "_")), "adj.P.Val", "logFC")
        }

        """
    }
}
