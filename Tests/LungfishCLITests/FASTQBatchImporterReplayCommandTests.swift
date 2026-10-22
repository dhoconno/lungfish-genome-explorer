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

    // MARK: - Lane C2-SHEETFIX, the pairing a record states

    private let pairedSample = SamplePair(
        sampleName: "S1", r1: URL(fileURLWithPath: "/data/S1_R1.fastq.gz"), r2: URL(fileURLWithPath: "/data/S1_R2.fastq.gz")
    )
    private let loneSample = SamplePair(sampleName: "S2", r1: URL(fileURLWithPath: "/data/S2.fastq.gz"), r2: nil)

    private func command(
        _ pair: SamplePair, _ pairing: FASTQBatchImporter.ImportPairing, durable: Bool = false
    ) -> [String] {
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/data/Project.lungfish"),
            platform: ImportPlatformRequest.given(.illumina),
            pairing: pairing
        )
        return FASTQBatchImporter.reproducibleImportCommand(pair: pair, config: config, durable: durable)
    }

    /// The pairing `import fastq` itself parses from `arguments`.
    private func parsedPairing(_ arguments: [String]) throws -> String {
        try ImportCommand.FastqSubcommand.parse(Array(arguments.dropFirst(3))).pairing
    }

    /// An R1/R2 pair imported with no `--pairing` ran paired. The record's `argv` keeps what was asked, `auto`, and its
    /// durable command names `paired`, so a replay pairs the files whatever detection does then.
    func testAnR1R2PairUnderAutoRecordsAutoAndReplaysPaired() throws {
        let asked = command(pairedSample, .auto)
        let durable = command(pairedSample, .auto, durable: true)

        XCTAssertEqual(optionValue("--pairing", in: asked), "auto", "argv keeps what was asked: \(asked)")
        XCTAssertEqual(optionValue("--pairing", in: durable), "paired", "\(durable)")
        XCTAssertEqual(try parsedPairing(asked), "auto")
        XCTAssertEqual(try parsedPairing(durable), "paired")
    }

    /// A pairing the user chose is recorded as given, in `argv` and in the durable command.
    func testAPairingTheUserChoseIsRecordedAsGiven() throws {
        for pairing in [FASTQBatchImporter.ImportPairing.single, .interleaved, .paired] {
            for durable in [false, true] {
                let arguments = command(loneSample, pairing, durable: durable)
                XCTAssertEqual(optionValue("--pairing", in: arguments), pairing.rawValue, "\(arguments)")
                XCTAssertEqual(try parsedPairing(arguments), pairing.rawValue)
            }
        }
    }

    /// A lone file imported with no `--pairing` names `interleaved` in the durable command when its records alternate
    /// mates and `auto` when they read single-end, so a replay keeps that single-end detected, not final. A sample
    /// sheet's command names `auto` for it, since one value replays every sample of the sheet.
    func testALoneFileUnderAutoReplaysWhatItsRecordsShowed() throws {
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/data/Project.lungfish"), platform: ImportPlatformRequest.given(.illumina)
        )
        let alternating = FASTQBatchImporter.RecordedPairing(mode: .interleaved, source: .detected)
        let single = FASTQBatchImporter.RecordedPairing(mode: .singleEnd, source: .detected)
        let sheetSample = SamplePair(
            sampleName: "S3", r1: URL(fileURLWithPath: "/data/S3.fastq.gz"), r2: nil,
            sampleSheetURL: URL(fileURLWithPath: "/data/samples.csv")
        )
        func durable(_ pair: SamplePair, _ imported: FASTQBatchImporter.RecordedPairing) -> [String] {
            FASTQBatchImporter.reproducibleImportCommand(pair: pair, config: config, durable: true, imported: imported)
        }

        XCTAssertEqual(optionValue("--pairing", in: durable(loneSample, alternating)), "interleaved")
        XCTAssertEqual(optionValue("--pairing", in: durable(loneSample, single)), "auto")
        XCTAssertEqual(optionValue("--pairing", in: durable(sheetSample, alternating)), "auto")
        XCTAssertEqual(try parsedPairing(durable(loneSample, alternating)), "interleaved")
        XCTAssertEqual(
            optionValue("--pairing", in: FASTQBatchImporter.reproducibleImportCommand(pair: loneSample, config: config)),
            "auto", "argv keeps what was asked"
        )
    }

    /// A record written before lane C2-SHEETFIX names no `--pairing`. Its replay goes out as recorded, so `import fastq`
    /// runs its default, `auto`, and detects the pairing again as the run that wrote the record did.
    func testAnOldRecordThatNamesNoPairingReplaysAsRecorded() throws {
        var old = command(pairedSample, .auto, durable: true)
        let index = try XCTUnwrap(old.firstIndex(of: "--pairing"))
        old.removeSubrange(index...(index + 1))

        XCTAssertEqual(QualityBinningReplay.arguments(old, stated: nil), old, "the replay adds no option")
        XCTAssertEqual(try parsedPairing(old), "auto")
    }
}
