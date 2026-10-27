// ImportConfigTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class ImportConfigTests: XCTestCase {

    func testImportConfigDefaultsFromPlatform() {
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp/test.lungfish"),
            platform: .illumina
        )
        XCTAssertEqual(config.sequencingPlatform, .illumina)
        XCTAssertTrue(config.optimizeStorage)
        XCTAssertEqual(config.clumpingTool, .auto)
        XCTAssertEqual(config.qualityBinning, .fiveStep)
        XCTAssertEqual(config.compressionLevel, .balanced)
        XCTAssertNil(config.newRecipe)
        XCTAssertFalse(config.forceReimport)
    }

    func testImportConfigONTDefaults() {
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp/test.lungfish"),
            platform: .ont
        )
        XCTAssertFalse(config.optimizeStorage)
        // ONT with no flags keeps auto, which clumps nothing for long reads (D8 B).
        XCTAssertEqual(config.clumpingTool, .auto)
        XCTAssertEqual(config.qualityBinning, QualityBinningScheme.fiveStep, "ONT bins in steps of five by default")
    }

    func testImportConfigExplicitOverrides() {
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp/test.lungfish"),
            platform: .illumina,
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: false,
            compressionLevel: .maximum,
            forceReimport: true
        )
        XCTAssertFalse(config.optimizeStorage)
        XCTAssertEqual(config.clumpingTool, .none)
        XCTAssertEqual(config.qualityBinning, .none)
        XCTAssertEqual(config.compressionLevel, .maximum)
        XCTAssertTrue(config.forceReimport)
    }

    func testImportConfigHonoursANamedClumpingToolForONT() {
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp/test.lungfish"),
            platform: .ont,
            clumpingTool: .bbtools
        )

        // A tool the user named wins on every platform (D8 B).
        XCTAssertTrue(config.optimizeStorage)
        XCTAssertEqual(config.clumpingTool, .bbtools)
    }

    func testImportConfigRecipeQualityBinningFallback() {
        // When qualityBinning is nil, should fall back to newRecipe?.qualityBinning
        // then platform default. Without a recipe, falls through to platform default.
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp/test.lungfish"),
            platform: .pacbio
        )
        XCTAssertEqual(config.qualityBinning, QualityBinningScheme.fiveStep, "PacBio takes its platform default, fiveStep")
        XCTAssertFalse(config.optimizeStorage)
        XCTAssertEqual(config.clumpingTool, .auto)
    }

    func testImportConfigDefaultThreads() {
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp/test.lungfish"),
            platform: .illumina
        )
        XCTAssertEqual(config.threads, 4)
    }

    func testImportConfigForceReimportDefaultFalse() {
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp/test.lungfish"),
            platform: .illumina
        )
        XCTAssertFalse(config.forceReimport)
    }

    func testImportConfigBackwardCompatNilRecipe() {
        // Old-style call with recipe: nil should still work
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp"), platform: .illumina,
            recipe: nil
        )
        XCTAssertNil(config.recipe)
        XCTAssertNil(config.newRecipe)
        // Default platform is .illumina
        XCTAssertEqual(config.sequencingPlatform, .illumina)
        XCTAssertEqual(config.qualityBinning, .fiveStep)
    }

    func testIlluminaAmpliconMergeRecipeIsAvailableBeforeGenotyping() throws {
        let recipe = try XCTUnwrap(
            RecipeRegistryV2.recipe(id: "illumina-amplicon-merge"),
            "Illumina amplicon merge must be a built-in import recipe so users can prepare sample bundles before running genotyping."
        )

        XCTAssertEqual(recipe.name, "Illumina Amplicon Merge")
        XCTAssertEqual(recipe.platforms, [.illumina])
        XCTAssertEqual(recipe.requiredInput, .paired)
        XCTAssertEqual(recipe.qualityBinning, .fiveStep, "the recipe keeps every Q10, Q20 and Q30 count (BIO-BIN)")
        XCTAssertEqual(recipe.steps.map(\.type), ["fastp-merge"])
        XCTAssertEqual(recipe.steps.first?.params?["keepUnmerged"]?.boolValue, false)
    }

    func testFastpMergeCanProduceMergedOnlySingleReadStreamForAmpliconImports() throws {
        let step = try FastpMergeStep(params: [
            "minOverlap": .int(20),
            "keepUnmerged": .bool(false),
        ])

        XCTAssertEqual(step.inputFormat, .pairedR1R2)
        XCTAssertEqual(step.outputFormat, .single)
    }
}
