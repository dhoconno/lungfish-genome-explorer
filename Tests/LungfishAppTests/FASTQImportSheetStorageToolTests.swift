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
}
