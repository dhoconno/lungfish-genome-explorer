// ImportConfigTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class ImportConfigTests: XCTestCase {

    func testImportConfigDefaultsFromPlatform() {
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp/test.lungfish"),
            platform: .illumina
        )
        XCTAssertEqual(config.platform, .illumina)
        XCTAssertTrue(config.optimizeStorage)
        XCTAssertEqual(config.qualityBinning, .illumina4)
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
        XCTAssertEqual(config.qualityBinning, QualityBinningScheme.none)
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
        XCTAssertEqual(config.qualityBinning, .none)
        XCTAssertEqual(config.compressionLevel, .maximum)
        XCTAssertTrue(config.forceReimport)
    }

    func testImportConfigRecipeQualityBinningFallback() {
        // When qualityBinning is nil, should fall back to newRecipe?.qualityBinning
        // then platform default. Without a recipe, falls through to platform default.
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp/test.lungfish"),
            platform: .pacbio
        )
        XCTAssertEqual(config.qualityBinning, .none, "PacBio platform default is .none")
        XCTAssertFalse(config.optimizeStorage)
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
            projectDirectory: URL(fileURLWithPath: "/tmp"),
            recipe: nil
        )
        XCTAssertNil(config.recipe)
        XCTAssertNil(config.newRecipe)
        // Default platform is .illumina
        XCTAssertEqual(config.platform, .illumina)
        XCTAssertEqual(config.qualityBinning, .illumina4)
    }

    func testIlluminaAmpliconMergeRecipeIsAvailableBeforeGenotyping() throws {
        let recipe = try XCTUnwrap(
            RecipeRegistryV2.recipe(id: "illumina-amplicon-merge"),
            "Illumina amplicon merge must be a built-in import recipe so users can prepare sample bundles before running genotyping."
        )

        XCTAssertEqual(recipe.name, "Illumina Amplicon Merge")
        XCTAssertEqual(recipe.platforms, [.illumina])
        XCTAssertEqual(recipe.requiredInput, .paired)
        XCTAssertEqual(recipe.qualityBinning, .illumina4)
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
