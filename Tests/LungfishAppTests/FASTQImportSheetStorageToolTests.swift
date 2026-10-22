// FASTQImportSheetStorageToolTests.swift - the Import FASTQ sheet refuses Trim Galore for a merging recipe
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishWorkflow

/// With a recipe that keeps merged reads beside its pairs, Trim Galore fails
/// at the storage step after the whole recipe has run. The sheet says so
/// beside the Compression Tool popup and keeps Import disabled until the user
/// picks BBTools clumpify or turns storage optimization off.
final class FASTQImportSheetStorageToolTests: XCTestCase {
    private func vsp2Option() throws -> FASTQImportSheetRecipeOption {
        let recipe = try XCTUnwrap((try? RecipeResolver.resolve("vsp2-target-enrichment", in: RecipeRegistryV2.builtinRecipes())))
        return FASTQImportSheetRecipeOption(recipe: recipe)
    }

    func testTheVSP2OptionKnowsItsOutputMixesMergedReadsWithPairs() throws {
        XCTAssertTrue(try vsp2Option().outputMixesMergedReadsAndPairs)
    }

    func testTrimGaloreWithVSP2IsRefusedWithBothWaysOut() throws {
        let refusal = try XCTUnwrap(FASTQImportConfigSheet.storageToolRefusal(
            recipe: try vsp2Option(), optimizeStorage: true, tool: .trimGalore
        ))
        XCTAssertTrue(refusal.contains("BBTools clumpify"), refusal)
        XCTAssertTrue(refusal.contains("skip storage optimization"), refusal)
    }

    func testEveryWayOutClearsTheRefusal() throws {
        let vsp2 = try vsp2Option()
        XCTAssertNil(FASTQImportConfigSheet.storageToolRefusal(recipe: vsp2, optimizeStorage: true, tool: .bbtools))
        XCTAssertNil(FASTQImportConfigSheet.storageToolRefusal(recipe: vsp2, optimizeStorage: false, tool: .trimGalore))
        XCTAssertNil(FASTQImportConfigSheet.storageToolRefusal(recipe: nil, optimizeStorage: true, tool: .trimGalore))
        let pairsOnly = FASTQImportSheetRecipeOption(id: "pairs", name: "Pairs only", presentationText: "")
        XCTAssertNil(FASTQImportConfigSheet.storageToolRefusal(recipe: pairsOnly, optimizeStorage: true, tool: .trimGalore))
    }

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
