// FASTQBatchImporterReplayCommandTests.swift - the replay command of an import and the parameters its record holds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
@testable import LungfishCLI
@testable import LungfishWorkflow

/// CHTC lane C2-MERGED, fix 4 of the review. Before the lane's last commit the replay command passed
/// `config.newRecipe?.id`, which is `illumina-paired-cleanup` for every run of the merged recipe, so
/// `--recipe wastewater-metagenomics` replayed without its preset and the ribosomal RNA reads came back. The command
/// now passes the name the run was given and one option for each switch an option set. Each test builds the
/// command, parses it with the real `import fastq` parser and resolves it the way the CLI does, then compares
/// the recipe that comes out with the one that ran.
final class FASTQBatchImporterReplayCommandTests: XCTestCase {
    private func resolved(_ name: String, switchOptions: [String: Bool] = [:]) throws -> Recipe {
        try XCTUnwrap(RecipeResolver.resolve(name, in: RecipeRegistryV2.builtinRecipes(), switchOptions: switchOptions))
    }

    private func replayArguments(for recipe: Recipe) -> [String] {
        let pair = SamplePair(
            sampleName: "S1",
            r1: URL(fileURLWithPath: "/data/S1_R1.fastq.gz"),
            r2: URL(fileURLWithPath: "/data/S1_R2.fastq.gz")
        )
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/data/Project.lungfish"),
            platform: ImportPlatformRequest.auto,
            newRecipe: recipe
        )
        return FASTQBatchImporter.reproducibleImportCommand(pair: pair, config: config)
    }

    private func optionValue(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// The recipe the replay command resolves to, parsed with `import fastq` itself. The first three words are the
    /// executable and the subcommand.
    private func replayed(_ arguments: [String]) throws -> (switchOptions: [String: Bool], recipe: Recipe) {
        let command = try ImportCommand.FastqSubcommand.parse(Array(arguments.dropFirst(3)))
        let resolution = try ImportCommand.FastqSubcommand.resolveImportRecipe(
            named: command.recipe,
            switchOptions: command.importOptions.switchOptions,
            recipes: RecipeRegistryV2.builtinRecipes(),
            refused: []
        )
        return (command.importOptions.switchOptions, try XCTUnwrap(resolution.newRecipe))
    }

    func testAWastewaterReplayWithDuplicatesKeptPassesTheNameAndTheSwitch() throws {
        let recipe = try resolved("wastewater-metagenomics", switchOptions: ["removeDuplicates": false])
        let arguments = replayArguments(for: recipe)

        XCTAssertEqual(optionValue("--recipe", in: arguments), "wastewater-metagenomics")
        XCTAssertTrue(arguments.contains("--no-remove-duplicates"))
        XCTAssertFalse(arguments.contains("--remove-duplicates"))
        XCTAssertFalse(arguments.contains(recipe.id), "the recipe file's id is not the name the run was given")
        XCTAssertFalse(
            arguments.contains("--remove-ribosomal-rna") || arguments.contains("--no-remove-ribosomal-rna"),
            "a value that came from the preset is not passed, so a replay follows the preset of the build that replays it"
        )

        let replay = try replayed(arguments)
        XCTAssertEqual(replay.switchOptions, ["removeDuplicates": false])
        XCTAssertEqual(replay.recipe.switchSettings, recipe.switchSettings)
        XCTAssertEqual(replay.recipe.activeSteps, recipe.activeSteps)
        XCTAssertEqual(replay.recipe.requestedName, "wastewater-metagenomics")
    }

    func testAVSP2ReplayWithNoOptionPassesTheAliasAndNoSwitch() throws {
        let recipe = try resolved("vsp2")
        let arguments = replayArguments(for: recipe)

        XCTAssertEqual(optionValue("--recipe", in: arguments), "vsp2")
        XCTAssertEqual(
            arguments.filter { $0.hasPrefix("--remove-") || $0.hasPrefix("--no-remove-") }, [],
            "no switch came from an option, so none is passed"
        )

        let replay = try replayed(arguments)
        XCTAssertEqual(replay.switchOptions, [:])
        XCTAssertEqual(replay.recipe.switchSettings, recipe.switchSettings)
        XCTAssertEqual(replay.recipe.activeSteps, recipe.activeSteps)
    }

    func testTheRecordNamesTheRequestedNameThePresetAndEachSwitchWithItsSource() throws {
        let recipe = try resolved("wastewater-metagenomics", switchOptions: ["removeDuplicates": false])
        let parameters = recipe.resolutionParameters

        XCTAssertEqual(parameters["recipeRequestedName"], .string("wastewater-metagenomics"))
        XCTAssertEqual(parameters["recipePreset"], .string("wastewater-metagenomics"))
        XCTAssertEqual(parameters["recipeSwitch.removeDuplicates"], .string("off (option)"))
        XCTAssertEqual(parameters["recipeSwitch.removeRibosomalRNA"], .string("on (preset)"))

        let vsp2 = try resolved("vsp2").resolutionParameters
        XCTAssertEqual(vsp2["recipeRequestedName"], .string("vsp2"))
        XCTAssertEqual(vsp2["recipePreset"], .string("vsp2-target-enrichment"))
        XCTAssertEqual(vsp2["recipeSwitch.removeDuplicates"], .string("on (preset)"))
        XCTAssertEqual(vsp2["recipeSwitch.removeRibosomalRNA"], .string("off (preset)"))
    }
}
