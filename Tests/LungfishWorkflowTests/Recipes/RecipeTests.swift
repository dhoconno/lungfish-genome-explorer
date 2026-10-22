// RecipeTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Testing
import Foundation
import LungfishCore
@testable import LungfishWorkflow

@Suite("Recipe")
struct RecipeTests {

    // MARK: - testParseMinimalRecipe

    @Test func testParseMinimalRecipe() throws {
        let json = """
        {
            "formatVersion": 1,
            "id": "minimal-recipe",
            "name": "Minimal Recipe",
            "platforms": ["illumina"],
            "requiredInput": "single",
            "steps": []
        }
        """
        let data = Data(json.utf8)
        let recipe = try JSONDecoder().decode(Recipe.self, from: data)

        #expect(recipe.formatVersion == 1)
        #expect(recipe.id == "minimal-recipe")
        #expect(recipe.name == "Minimal Recipe")
        #expect(recipe.description == nil)
        #expect(recipe.author == nil)
        #expect(recipe.tags == [])
        #expect(recipe.platforms == [IngestionPlatform.illumina])
        #expect(recipe.requiredInput == Recipe.InputRequirement.single)
        #expect(recipe.qualityBinning == nil)
        #expect(recipe.steps.isEmpty)
    }

    // MARK: - testParseFullRecipe

    @Test func testParseFullRecipe() throws {
        let json = """
        {
            "formatVersion": 1,
            "id": "full-recipe",
            "name": "Full Recipe",
            "description": "A complete recipe for testing.",
            "author": "Test Author",
            "tags": ["test", "illumina"],
            "platforms": ["illumina", "ont"],
            "requiredInput": "paired",
            "qualityBinning": "illumina4",
            "steps": [
                {
                    "type": "fastp-trim",
                    "label": "Trim adapters",
                    "params": {
                        "detectAdapter": true,
                        "quality": 20,
                        "window": 4,
                        "prefix": "sample"
                    }
                },
                {
                    "type": "seqkit-length-filter",
                    "label": "Length filter"
                }
            ]
        }
        """
        let data = Data(json.utf8)
        let recipe = try JSONDecoder().decode(Recipe.self, from: data)

        #expect(recipe.formatVersion == 1)
        #expect(recipe.id == "full-recipe")
        #expect(recipe.name == "Full Recipe")
        #expect(recipe.description == "A complete recipe for testing.")
        #expect(recipe.author == "Test Author")
        #expect(recipe.tags == ["test", "illumina"])
        #expect(recipe.platforms == [IngestionPlatform.illumina, IngestionPlatform.ont])
        #expect(recipe.requiredInput == Recipe.InputRequirement.paired)
        #expect(recipe.qualityBinning == QualityBinningScheme.illumina4)
        #expect(recipe.steps.count == 2)

        let trimStep = recipe.steps[0]
        #expect(trimStep.type == "fastp-trim")
        #expect(trimStep.label == "Trim adapters")
        #expect(trimStep.params?["detectAdapter"]?.boolValue == true)
        #expect(trimStep.params?["quality"]?.intValue == 20)
        #expect(trimStep.params?["window"]?.intValue == 4)
        #expect(trimStep.params?["prefix"]?.stringValue == "sample")

        let lenStep = recipe.steps[1]
        #expect(lenStep.type == "seqkit-length-filter")
        #expect(lenStep.label == "Length filter")
        #expect(lenStep.params == nil)
    }

    // MARK: - testRoundTrip

    @Test func testRoundTrip() throws {
        let json = """
        {
            "formatVersion": 1,
            "id": "roundtrip-recipe",
            "name": "Round-Trip Recipe",
            "description": "Tests encode/decode fidelity.",
            "author": "Test",
            "tags": ["roundtrip"],
            "platforms": ["pacbio"],
            "requiredInput": "any",
            "qualityBinning": "none",
            "steps": [
                {
                    "type": "some-tool",
                    "label": "Do something",
                    "params": {
                        "flag": true,
                        "count": 42,
                        "ratio": 0.75,
                        "name": "hello"
                    }
                }
            ]
        }
        """
        let data = Data(json.utf8)
        let original = try JSONDecoder().decode(Recipe.self, from: data)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Recipe.self, from: encoded)

        #expect(original == decoded)
        #expect(decoded.id == "roundtrip-recipe")
        #expect(decoded.steps[0].params?["flag"]?.boolValue == true)
        #expect(decoded.steps[0].params?["count"]?.intValue == 42)
        #expect(decoded.steps[0].params?["ratio"]?.doubleValue == 0.75)
        #expect(decoded.steps[0].params?["name"]?.stringValue == "hello")
    }

    // MARK: - test_decodeRefusesUnknownFormatVersion

    /// A build reads only the format versions it knows. A newer file holds switches an older build would ignore,
    /// so running it would run every step (ruling BIO-PRESET P3, QA review point 6).
    @Test func test_decodeRefusesUnknownFormatVersion() throws {
        func recipeJSON(version: Int) -> Data {
            Data("""
            {
                "formatVersion": \(version),
                "id": "version-\(version)",
                "name": "Version \(version)",
                "platforms": ["illumina"],
                "requiredInput": "any",
                "steps": [{ "type": "fastp-trim" }]
            }
            """.utf8)
        }
        for version in [0, 3] {
            #expect(throws: (any Error).self, "formatVersion \(version) must be refused") {
                try JSONDecoder().decode(Recipe.self, from: recipeJSON(version: version))
            }
        }
        for version in [1, 2] {
            let recipe = try JSONDecoder().decode(Recipe.self, from: recipeJSON(version: version))
            #expect(recipe.formatVersion == version)
        }
    }

    // MARK: - testLoadBundledVSP2Recipe

    @Test func testLoadBundledVSP2Recipe() throws {
        let resolvedURL = try #require(
            RecipeBundleAccessor.recipesDirectoryURL()?
                .appendingPathComponent("illumina-paired-cleanup.recipe.json"),
            "illumina-paired-cleanup.recipe.json not found in workflow resources"
        )

        let data = try Data(contentsOf: resolvedURL)
        let recipe = try #require(try RecipeResolver.resolve(
            "vsp2", in: [try JSONDecoder().decode(Recipe.self, from: data)]
        ))
        let steps = recipe.activeSteps

        #expect(recipe.id == "illumina-paired-cleanup")
        #expect(recipe.name == "Illumina paired-end cleanup")
        #expect(recipe.resolution?.preset?.name == "VSP2 target enrichment")
        #expect(recipe.platforms == [IngestionPlatform.illumina])
        #expect(recipe.requiredInput == Recipe.InputRequirement.paired)
        #expect(recipe.qualityBinning == QualityBinningScheme.illumina4)
        #expect(recipe.steps.count == 6)

        // The vsp2 preset keeps ribosomal RNA reads, so its run leaves the rRNA filter out.
        let stepTypes = steps.map { $0.type }
        #expect(stepTypes == [
            "fastp-dedup",
            "fastp-trim",
            "deacon-scrub",
            "fastp-merge",
            "seqkit-length-filter"
        ])
    }
}
