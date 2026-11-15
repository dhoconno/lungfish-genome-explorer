// RNASeqExportDesignTests.swift - The design check before a batch step, and the cutoff the DESeq2 template holds (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ADJ-BULK C7 N1 (`SCR/rulings/ADJ-BULK.md:104-107`) and C5 N1 (`:82-85`). A batch nested in or equal to a level of a design
// factor, or holding only whole levels of it so that `~ batch + design` loses full rank, refuses ComBat-seq and sva.

import XCTest
@testable import LungfishWorkflow

final class RNASeqExportDesignTests: XCTestCase {
    typealias Step = RNASeqExportSettings.BatchCorrection

    private func settings(_ step: Step, batch: String? = "batch", design: [String] = ["day"]) -> RNASeqExportSettings {
        RNASeqExportSettings(
            design: design, contrasts: [.init(factor: design.last ?? "day", numerator: "D3", denominator: "Dm8")], batch: batch, batchCorrection: step)
    }

    /// Four animals on six days, as C7: batch B holds exactly days 3 and 10, which is eight samples.
    private var c7: RNASeqExportSampleTable {
        var rows: [[String]] = []
        for animal in 1...4 {
            for day in ["Dm8", "D1", "D3", "D5", "D7", "D10"] {
                rows.append(["a\(animal)-\(day)", "a\(animal)", day, ["D3", "D10"].contains(day) ? "B" : "A"])
            }
        }
        return RNASeqExportSampleTable(columns: ["sample_id", "animal", "day", "batch"], rows: rows)
    }

    private func groups(batches: [String]) -> RNASeqExportSampleTable {
        RNASeqExportSampleTable(columns: ["sample_id", "group", "batch"], rows: batches.enumerated().map { index, batch in
            ["S\(index + 1)", index < 6 ? "g1" : "g2", batch]
        })
    }

    func testAC7ShapedSheetRefusesCombatSeqAndSva() {
        for step in [Step.combatSeq, .sva] {
            XCTAssertThrowsError(try RNASeqExportDesignCheck.check(settings(step), samples: c7)) {
                let words = $0.localizedDescription
                for needle in ["batch", "day", "D3", "D10", step.rawValue, "full rank"] {
                    XCTAssertTrue(words.contains(needle), "\(needle) is missing from \(words)")
                }
            }
        }
    }

    func testABatchNestedInOneGroupRefusesCombatSeqAndSva() {
        let nested = groups(batches: ["X", "X", "X", "Y", "Y", "Y", "Y", "Y", "Y", "Y", "Y", "Y"])
        for step in [Step.combatSeq, .sva] {
            XCTAssertThrowsError(try RNASeqExportDesignCheck.check(settings(step, design: ["group"]), samples: nested)) {
                let words = $0.localizedDescription
                for needle in ["batch", "X", "group", "g1", step.rawValue] {
                    XCTAssertTrue(words.contains(needle), "\(needle) is missing from \(words)")
                }
            }
        }
    }

    func testABatchThatCrossesTheDesignLevelsPasses() throws {
        let crossing = groups(batches: ["X", "Y", "X", "Y", "X", "Y", "Y", "X", "Y", "X", "Y", "X"])
        for step in [Step.combatSeq, .sva] {
            XCTAssertNoThrow(try RNASeqExportDesignCheck.check(settings(step, design: ["group"]), samples: crossing))
        }
    }

    func testNoBatchStepNeedsNoCheck() throws {
        try RNASeqExportDesignCheck.check(settings(.none, batch: nil), samples: c7)
    }

    func testAMissingColumnAndAMissingBatchAreRefusedWithWhatToDo() {
        XCTAssertThrowsError(try RNASeqExportDesignCheck.check(settings(.combatSeq, design: ["treatment"]), samples: c7)) {
            XCTAssertTrue($0.localizedDescription.contains("treatment") && $0.localizedDescription.contains("sample_id, animal, day, batch"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try RNASeqExportDesignCheck.check(settings(.sva, batch: nil), samples: c7)) {
            XCTAssertTrue($0.localizedDescription.contains("--batch"), $0.localizedDescription)
        }
    }

    func testTheTemplatesRepeatTheCheckBeforeTheBatchStep() throws {
        for text in [RNASeqExportTemplates.deseq2(settings(.combatSeq)), RNASeqExportTemplates.edgerLimmaDream(settings(.combatSeq))] {
            let check = try XCTUnwrap(text.range(of: "check_batch_design("), text)
            let step = try XCTUnwrap(text.range(of: "ComBat_seq("), text)
            XCTAssertLessThan(check.lowerBound, step.lowerBound)
        }
        XCTAssertFalse(RNASeqExportTemplates.deseq2(settings(.none, batch: nil)).contains("ComBat_seq("))
    }

    func testTheDeseq2TemplateHoldsTheCutoffAsAlphaForBothCutoffs() {
        for cutoff in [0.05, 0.1] {
            var chosen = settings(.none, batch: nil)
            chosen.padjCutoff = cutoff
            let text = RNASeqExportTemplates.deseq2(chosen)
            XCTAssertTrue(text.contains("padj_cutoff <- \(cutoff)"), text)
            XCTAssertTrue(text.contains("alpha = padj_cutoff"), text)
            if cutoff == 0.1 { XCTAssertFalse(text.contains("0.05"), "the default cutoff leaks into the template") }
        }
    }

    func testTheBarGatesTheMleFoldChangeAndAShrunkenValueOnlyComesBeside() {
        var chosen = settings(.none, batch: nil)
        XCTAssertTrue(RNASeqExportTemplates.deseq2(chosen).contains("lfc_bar <- NULL"))
        chosen.lfcBar = 1.4
        let text = RNASeqExportTemplates.deseq2(chosen)
        XCTAssertTrue(text.contains("lfc_bar <- 1.4"), text)
        XCTAssertTrue(text.contains("abs(table$log2FoldChange) >= lfc_bar"), text)
        XCTAssertTrue(text.contains("log2FoldChange_shrunk"), text)
        XCTAssertFalse(text.contains("abs(table$log2FoldChange_shrunk)"), "the shrunken value never gates")
    }

    func testBothTemplatesTakeSizeFactorsFromHostRowsOnly() {
        let chosen = settings(.none, batch: nil)
        XCTAssertTrue(RNASeqExportTemplates.deseq2(chosen).contains("controlGenes = which(host)"))
        XCTAssertTrue(RNASeqExportTemplates.edgerLimmaDream(chosen).contains("counts[host, , drop = FALSE]"))
    }

    func testTheDreamPartStopsInWordsWhenVariancePartitionIsMissing() {
        let text = RNASeqExportTemplates.edgerLimmaDream(settings(.none, batch: nil))
        XCTAssertTrue(text.contains("requireNamespace(\"variancePartition\""), text)
        XCTAssertTrue(text.contains("variancePartition is not installed"), text)
    }

    /// In R, `paste0("(1|", character(0), ")")` is `"(1|)"`, so an empty `random_terms` made the formula `~ group + (1|)`, and the
    /// first GD run of C5 in `env-r-dream` stopped on it. The random part is built only when a column is named.
    func testTheDreamFormulaHasNoRandomTermWhenNoColumnIsNamed() {
        let text = RNASeqExportTemplates.edgerLimmaDream(settings(.none, batch: nil))
        XCTAssertTrue(text.contains("random_part <- if (length(random_terms) > 0)"), text)
        XCTAssertTrue(text.contains("c(unique(model_terms), random_part)"), text)
    }
}
