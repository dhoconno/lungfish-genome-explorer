// RecipeResolverTests.swift - The merged recipe's presets, switches and refusals (CHTC lane C2-MERGED)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import Testing
@testable import LungfishWorkflow

@Suite("RecipeResolver")
struct RecipeResolverTests {

    private static let mergedID = "illumina-paired-cleanup"

    private func builtins() throws -> [Recipe] {
        let recipes = RecipeRegistryV2.builtinRecipes()
        try #require(recipes.contains { $0.id == Self.mergedID }, "the merged recipe file did not load")
        return recipes
    }

    private func setting(_ id: String, of recipe: Recipe) throws -> RecipeSwitchSetting {
        try #require(recipe.switchSettings.first { $0.id == id })
    }

    /// Both old ids and the `vsp2` alias run the merged recipe at their preset's switch values (ruling BIO-PRESET).
    @Test func test_oldIdsResolveToPresets() throws {
        let recipes = try builtins()
        for name in ["vsp2", "VSP2", "vsp2-target-enrichment", " vsp2-target-enrichment "] {
            let recipe = try #require(try RecipeResolver.resolve(name, in: recipes))
            #expect(recipe.id == Self.mergedID)
            #expect(recipe.resolution?.preset?.id == "vsp2-target-enrichment")
            #expect(recipe.resolution?.requestedName == name.trimmingCharacters(in: .whitespaces))
            #expect(try setting("removeDuplicates", of: recipe) == RecipeSwitchSetting(
                id: "removeDuplicates", label: "Remove duplicate reads", value: true, source: .preset))
            #expect(try setting("removeRibosomalRNA", of: recipe) == RecipeSwitchSetting(
                id: "removeRibosomalRNA", label: "Remove ribosomal RNA reads", value: false, source: .preset))
            #expect(recipe.activeSteps.map(\.type) == [
                "fastp-dedup", "fastp-trim", "deacon-scrub", "fastp-merge", "seqkit-length-filter",
            ])
        }

        let wastewater = try #require(try RecipeResolver.resolve("wastewater-metagenomics", in: recipes))
        #expect(wastewater.id == Self.mergedID)
        #expect(wastewater.resolution?.preset?.id == "wastewater-metagenomics")
        #expect(try setting("removeDuplicates", of: wastewater).value == true)
        #expect(try setting("removeRibosomalRNA", of: wastewater).value == true)
        #expect(wastewater.switchSettings.allSatisfy { $0.source == .preset })
        #expect(wastewater.activeSteps.map(\.type) == [
            "fastp-dedup", "fastp-trim", "deacon-scrub", "deacon-ribo-filter", "fastp-merge", "seqkit-length-filter",
        ])
    }

    /// The merged id with no switch keeps rRNA and removes duplicates, each from the recipe default (QA point 5).
    @Test func test_defaultKeepsRibosomalRNA() throws {
        let recipe = try #require(try RecipeResolver.resolve(Self.mergedID, in: try builtins()))
        #expect(recipe.resolution?.preset == nil)
        #expect(try setting("removeRibosomalRNA", of: recipe).value == false)
        #expect(try setting("removeRibosomalRNA", of: recipe).source == .recipeDefault)
        #expect(try setting("removeDuplicates", of: recipe).value == true)
        #expect(!recipe.activeSteps.contains { $0.type == "deacon-ribo-filter" })
    }

    /// An option beats the preset, and a replay passes only the option.
    @Test func test_switchOptionBeatsPreset() throws {
        let recipe = try #require(try RecipeResolver.resolve(
            "wastewater-metagenomics", in: try builtins(), switchOptions: ["removeDuplicates": false]
        ))
        #expect(try setting("removeDuplicates", of: recipe) == RecipeSwitchSetting(
            id: "removeDuplicates", label: "Remove duplicate reads", value: false, source: .option))
        #expect(try setting("removeRibosomalRNA", of: recipe).source == .preset)
        #expect(recipe.switchOptionArguments == ["--no-remove-duplicates"])
        #expect(recipe.requestedName == "wastewater-metagenomics")
        #expect(recipe.activeSteps.first?.type == "fastp-trim")
    }

    /// A display name never resolves, and neither does a name no file holds.
    @Test func test_namesNeverMatch() throws {
        let recipes = try builtins()
        for name in ["VSP2 target enrichment", "Illumina paired-end cleanup", "Wastewater metagenomics", "vsp"] {
            #expect(try RecipeResolver.resolve(name, in: recipes) == nil)
        }
    }

    /// A switch option the recipe has no switch for is refused by name (UX point 6).
    @Test func test_unknownSwitchIsRefused() throws {
        #expect(throws: RecipeResolutionError.unknownSwitch("removeDuplicates", recipeID: "illumina-amplicon-merge")) {
            try RecipeResolver.resolve(
                "illumina-amplicon-merge", in: try builtins(), switchOptions: ["removeDuplicates": false]
            )
        }
        #expect(RecipeSwitch.optionName(for: "removeRibosomalRNA") == "remove-ribosomal-rna")
        #expect(RecipeSwitch.optionName(for: "removeDuplicates") == "remove-duplicates")
    }

    /// The two old files are gone, and the merged file's steps read as written.
    @Test func test_bundledRecipesHoldTheMergedFile() throws {
        let recipes = try builtins()
        #expect(Set(recipes.map(\.id)) == [Self.mergedID, "illumina-amplicon-merge"])
        let merged = try #require(recipes.first { $0.id == Self.mergedID })
        #expect(merged.formatVersion == 2)
        #expect(merged.sourceSHA256?.count == 64)
        #expect(merged.steps.map(\.type) == [
            "fastp-dedup", "fastp-trim", "deacon-scrub", "deacon-ribo-filter", "fastp-merge", "seqkit-length-filter",
        ])
        #expect(merged.presets.map(\.id) == ["vsp2-target-enrichment", "wastewater-metagenomics"])
        #expect(RecipeResolver.resolvableNames(in: [merged]) == [
            Self.mergedID, "vsp2-target-enrichment", "wastewater-metagenomics", "vsp2",
        ])
    }

    /// A newer file in the user folder is reported as refused, by its id, and never resolves as unknown
    /// (QA point 6).
    @Test func test_newerRecipeFileIsReported() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("recipe-registry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let folder = RecipeRegistryV2.userRecipesDirectoryURL(applicationSupportDirectory: support)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
        {"formatVersion": 3, "id": "future-recipe", "name": "Future", "platforms": ["illumina"],
         "requiredInput": "any", "steps": []}
        """.utf8).write(to: folder.appendingPathComponent("future.recipe.json"))

        let loaded = RecipeRegistryV2.userRecipes(applicationSupportDirectory: support)
        #expect(loaded.isEmpty)
        let refused = RecipeRegistryV2.refusedRecipeFiles(applicationSupportDirectory: support)
        let refusal = try #require(refused.first { $0.recipeID == "future-recipe" })
        #expect(refusal.fileName == "future.recipe.json")
        #expect(refusal.formatVersion == 3)

        do {
            _ = try RecipeResolver.resolve("future-recipe", in: loaded, refused: refused)
            Issue.record("a refused file resolved")
        } catch BatchImportError.unsupportedRecipe(let name, let reason) {
            #expect(name == "future-recipe")
            #expect(reason.contains("formatVersion 3"))
        }
    }

    /// A switch must name one step, and a preset only switches the recipe declares.
    @Test func test_switchThatNamesNoStepIsRefused() throws {
        let json = Data("""
        {"formatVersion": 2, "id": "bad", "name": "Bad", "platforms": ["illumina"], "requiredInput": "any",
         "switches": [{"id": "removeDuplicates", "label": "Remove duplicate reads", "default": true,
                       "gates": "fastp-dedup"}],
         "steps": [{"type": "fastp-trim"}]}
        """.utf8)
        #expect(throws: RecipeSwitchError.self) {
            try JSONDecoder().decode(Recipe.self, from: json)
        }
    }

    /// The planner leaves out a step a switch turned off, so keeping duplicates drops only the dedup flags.
    @Test func test_planLeavesOutTurnedOffSteps() throws {
        let recipes = try builtins()
        let engine = RecipeEngine()
        let vsp2 = try #require(try RecipeResolver.resolve("vsp2", in: recipes))
        let plan = try engine.plan(recipe: vsp2, inputFormat: .pairedR1R2)
        guard case .fusedFastp(_, _, _, let components) = try #require(plan.first) else {
            Issue.record("expected a fused fastp call first")
            return
        }
        #expect(components.map(\.typeID) == ["fastp-dedup", "fastp-trim"])

        let kept = try #require(try RecipeResolver.resolve(
            "vsp2", in: recipes, switchOptions: ["removeDuplicates": false]
        ))
        let keptPlan = try engine.plan(recipe: kept, inputFormat: .pairedR1R2)
        guard case .singleStep(let first, _) = try #require(keptPlan.first) else {
            Issue.record("expected the trim step alone first")
            return
        }
        #expect(first is FastpTrimStep)
    }

    /// A turned-off step keeps its place in the recipe: rRNA removal turned off comes after the three steps that run
    /// before it, so the record shows it after human read removal.
    @Test func test_turnedOffStepsKeepTheirPlace() throws {
        let recipes = try builtins()
        let vsp2 = try #require(try RecipeResolver.resolve("vsp2", in: recipes))
        #expect(vsp2.turnedOffSteps.map(\.step.type) == ["deacon-ribo-filter"])
        #expect(vsp2.turnedOffSteps.map(\.activeStepsBefore) == [3])
        #expect(vsp2.turnedOffSteps.first?.setting.source == .preset)

        let bare = try #require(try RecipeResolver.resolve(
            Self.mergedID, in: recipes, switchOptions: ["removeDuplicates": false]
        ))
        #expect(bare.turnedOffSteps.map(\.step.type) == ["fastp-dedup", "deacon-ribo-filter"])
        #expect(bare.turnedOffSteps.map(\.activeStepsBefore) == [0, 2])
        #expect(bare.turnedOffSteps.map(\.setting.source) == [.option, .recipeDefault])
    }
}
