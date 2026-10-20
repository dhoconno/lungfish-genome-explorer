// ClumpingToolRecipeOutputTests.swift - storage tools that cannot keep a recipe's output together
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// Trim Galore keeps mates together by splitting a file of pairs into R1 and
/// R2, so it refuses a file that also holds merged reads. A recipe that merges
/// pairs and keeps the unmerged ones writes exactly such a file, and before
/// 2026-10-20 the import found out only after the whole recipe had run.
final class ClumpingToolRecipeOutputTests: XCTestCase {
    private func builtin(_ id: String) throws -> Recipe {
        try XCTUnwrap(RecipeRegistryV2.builtinRecipes().first { $0.id == id })
    }

    func testVSP2OutputMixesMergedReadsWithPairs() throws {
        XCTAssertTrue(try builtin("vsp2-target-enrichment").outputMixesMergedReadsAndPairs)
    }

    func testAMergeThatDropsTheUnmergedMatesLeavesOnlyMergedReads() {
        let recipe = Recipe(
            id: "merge-only", name: "Merge only", requiredInput: .paired,
            steps: [RecipeStep(type: "fastp-merge", label: nil, params: ["keepUnmerged": .bool(false)])]
        )
        XCTAssertFalse(recipe.outputMixesMergedReadsAndPairs)
    }

    func testARecipeWithoutAMergeKeepsOnlyPairs() {
        let recipe = Recipe(
            id: "dedup-trim", name: "Dedup and trim", requiredInput: .paired,
            steps: [
                RecipeStep(type: "fastp-dedup", label: nil, params: nil),
                RecipeStep(type: "fastp-trim", label: nil, params: nil),
            ]
        )
        XCTAssertFalse(recipe.outputMixesMergedReadsAndPairs)
    }

    func testLegacyRecipesWithAPairedEndMergeMixTheirOutput() {
        XCTAssertTrue(ProcessingRecipe.illuminaVSP2TargetEnrichment.outputMixesMergedReadsAndPairs)
        XCTAssertTrue(ProcessingRecipe.illuminaWGS.outputMixesMergedReadsAndPairs)
        XCTAssertFalse(ProcessingRecipe.pacbioHiFi.outputMixesMergedReadsAndPairs)
    }

    func testTrimGaloreRefusesAMixedRecipeOutputAndNamesBothWaysOut() throws {
        let refusal = try XCTUnwrap(ClumpingTool.trimGalore.refusalToStore(
            recipeNamed: "VSP2 Target Enrichment", outputMixesMergedReadsAndPairs: true
        ))
        XCTAssertTrue(refusal.contains("Trim Galore"), refusal)
        XCTAssertTrue(refusal.contains("VSP2 Target Enrichment"), refusal)
        XCTAssertTrue(refusal.contains("BBTools clumpify"), refusal)
        XCTAssertTrue(refusal.contains("skip storage optimization"), refusal)
    }

    func testEveryOtherCaseStoresTheRecipeOutput() {
        for tool in [ClumpingTool.auto, .bbtools, .none] {
            XCTAssertNil(tool.refusalToStore(recipeNamed: "VSP2", outputMixesMergedReadsAndPairs: true), "\(tool)")
        }
        XCTAssertNil(ClumpingTool.trimGalore.refusalToStore(recipeNamed: "WGS", outputMixesMergedReadsAndPairs: false))
    }
}
