// FASTQIngestionServiceRecipeNameTests.swift - the --recipe value the Import FASTQ sheet passes for its recipe choice
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishIO
@testable import LungfishWorkflow

/// CHTC lane C2-MERGED, fix 5 of the review. `FASTQIngestionService.resolvedRecipeName(for:)` lost its match by
/// name when the old VSP2 recipe became a preset of the merged recipe (ruling BIO-PRESET P3). It now compares the
/// legacy recipe's id with the built-in's. Each test reads the value the sheet would pass as `--recipe`, then
/// resolves it the way `import fastq` does.
final class FASTQIngestionServiceRecipeNameTests: XCTestCase {
    private func configuration(recipeName: String?, postImportRecipe: ProcessingRecipe?) -> FASTQImportConfiguration {
        FASTQImportConfiguration(
            inputFiles: [URL(fileURLWithPath: "/data/S1_R1.fastq.gz"), URL(fileURLWithPath: "/data/S1_R2.fastq.gz")],
            detectedPlatform: LungfishIO.SequencingPlatform.illumina,
            confirmedPlatform: LungfishIO.SequencingPlatform.illumina,
            pairingMode: .pairedEnd,
            qualityBinning: .none,
            skipClumpify: false,
            deleteOriginals: false,
            postImportRecipe: postImportRecipe,
            resolvedPlaceholders: [:],
            recipeName: recipeName,
            compressionLevel: nil
        )
    }

    private func switchValue(_ id: String, of recipe: Recipe) -> Bool? {
        recipe.switchSettings.first { $0.id == id }?.value
    }

    func testARecipeNameFromTheSheetComesBackUnchanged() {
        let config = configuration(recipeName: "wastewater-metagenomics", postImportRecipe: nil)
        XCTAssertEqual(FASTQIngestionService.resolvedRecipeName(for: config), "wastewater-metagenomics")
    }

    func testTheLegacyVSP2RecipeIsPassedAsTheVSP2PresetAndResolvesToIt() throws {
        let config = configuration(recipeName: nil, postImportRecipe: .illuminaVSP2TargetEnrichment)
        let name = try XCTUnwrap(FASTQIngestionService.resolvedRecipeName(for: config))
        XCTAssertEqual(name, "vsp2-target-enrichment")

        let recipe = try XCTUnwrap(RecipeResolver.resolve(name, in: RecipeRegistryV2.builtinRecipes()))
        XCTAssertEqual(recipe.resolution?.preset?.id, "vsp2-target-enrichment")
        XCTAssertEqual(switchValue("removeRibosomalRNA", of: recipe), false, "the VSP2 preset keeps ribosomal RNA reads")
        XCTAssertEqual(switchValue("removeDuplicates", of: recipe), true)
    }

    func testARecipeNamedLikeTheLegacyOneIsPassedByNameAndResolvesToNoRecipe() throws {
        let variant = ProcessingRecipe(
            name: "My VSP2 variant", steps: ProcessingRecipe.illuminaVSP2TargetEnrichment.steps
        )
        let config = configuration(recipeName: nil, postImportRecipe: variant)
        let name = try XCTUnwrap(FASTQIngestionService.resolvedRecipeName(for: config))
        XCTAssertEqual(name, "my vsp2 variant")
        XCTAssertNil(
            try RecipeResolver.resolve(name, in: RecipeRegistryV2.builtinRecipes()),
            "the match by name that the ruling removed"
        )
    }

    /// A recipe file another launch wrote holds that launch's id for the built-in, since the id defaults to
    /// `UUID()`. It is a recipe like any other and does not map to the preset.
    func testACopyOfTheLegacyRecipeWithAnotherIdIsNotTheVSP2Preset() throws {
        let legacy = ProcessingRecipe.illuminaVSP2TargetEnrichment
        let copy = ProcessingRecipe(name: legacy.name, steps: legacy.steps)
        XCTAssertNotEqual(copy.id, legacy.id)

        let config = configuration(recipeName: nil, postImportRecipe: copy)
        let name = try XCTUnwrap(FASTQIngestionService.resolvedRecipeName(for: config))
        XCTAssertEqual(name, "illumina vsp2 target enrichment")
        XCTAssertNil(try RecipeResolver.resolve(name, in: RecipeRegistryV2.builtinRecipes()))
    }
}
