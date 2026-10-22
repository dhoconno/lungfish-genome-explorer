// FASTQImportSheetStorageToolTests.swift - the Import FASTQ sheet's recipe options, read without driving the sheet
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishWorkflow

/// Until 2026-10-22 this class pinned the sheet's refusal of Trim Galore for a recipe that keeps merged reads beside its
/// pairs. Lane C2-TRIMGALORE removed that refusal, because the storage step now splits such a file by mate name, and
/// `FASTQImportConfigurationTests.importSheetStaysEnabledForAMergingRecipeWithTrimGalore` drives the sheet through
/// that case. What stays here reads a recipe option's text.
final class FASTQImportSheetStorageToolTests: XCTestCase {
    /// CHTC lane C2-MERGED fix 2. The Workflow line lists the steps that run. The merged recipe at its defaults keeps
    /// ribosomal RNA reads, so its line does not name the step that removes them, and the wastewater preset does.
    func testTheWorkflowLineListsOnlyTheStepsThatRun() throws {
        let recipes = RecipeRegistryV2.builtinRecipes()
        let merged = try XCTUnwrap(recipes.first { $0.id == "illumina-paired-cleanup" })
        let wastewater = try XCTUnwrap(try RecipeResolver.resolve("wastewater-metagenomics", in: recipes))

        func workflowLine(_ recipe: Recipe) throws -> String {
            let text = FASTQImportSheetRecipeOption(recipe: recipe).presentationText
            return try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasPrefix("Workflow: ") }, text)
        }
        let mergedLine = try workflowLine(merged)
        let wastewaterLine = try workflowLine(wastewater)
        XCTAssertFalse(mergedLine.contains("Remove ribosomal RNA reads"), mergedLine)
        XCTAssertTrue(wastewaterLine.contains("Remove ribosomal RNA reads"), wastewaterLine)
    }
}
