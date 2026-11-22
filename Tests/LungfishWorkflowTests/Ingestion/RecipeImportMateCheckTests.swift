// RecipeImportMateCheckTests.swift - An import with a recipe refuses a loose R1 and R2 that do not pair before fastp runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// What one import logged: its failure words and whether a step started.
private final class RecipeImportMateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    /// Records a step start and cancels the import's task right there, before the step launches its tool, so no
    /// fastp or clumpify runs at the base or after the fix (`NativeToolRunner.runProcess` checks for a cancel
    /// before it spawns).
    func observe(_ event: ImportLogEvent) {
        guard case .stepStart = event else { return }
        lock.withLock { started = true }
        withUnsafeCurrentTask { $0?.cancel() }
    }

    var startedAStep: Bool { lock.withLock { started } }
}

/// BIO ruling BIO-ROUTES-2, binding items 1 and 7 (S1). An import with a recipe handed the person's loose R1 and R2 to
/// fastp at its first step (`FastpTrimStep`, `FastpDedupStep`, and the old-format recipe's paired trims), which pairs
/// two files by position: a cut R2 left the rest of R1 out, and an R2 out of step joined two fragments in each pair,
/// with no word. The importer now reads both files whole before the recipe and refuses them with its own words.
final class RecipeImportMateCheckTests: XCTestCase {

    var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "recipe-import-mates").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    static let cutWords = "Paired FASTQ mates do not match: S_R1.fastq has 200 reads but S_R2.fastq has 120. Nothing was imported."
    static let outOfStepWords = "Paired FASTQ mates are out of step at record 2: S_R1.fastq has 'frag2/1' but S_R2.fastq has 'frag3/2'. The two files do not list the same fragments in the same order, so nothing was written."

    func testA200ReadR1WithA120ReadR2IsRefusedBeforeEveryRecipe() async throws {
        let r1 = try writeMates("S_R1.fastq", names: (1...200).map { "frag\($0)/1" })
        let r2 = try writeMates("S_R2.fastq", names: (1...120).map { "frag\($0)/2" })

        for recipe in RecipeKind.allCases {
            let outcome = await importOutcome(recipe, r1: r1, r2: r2)
            XCTAssertEqual(outcome.words, Self.cutWords, recipe.rawValue)
            XCTAssertEqual(outcome.startedAStep, false, recipe.rawValue)
            XCTAssertEqual(outcome.bundleExists, false, recipe.rawValue)
        }
    }

    func testAShuffledR2IsRefusedBeforeEveryRecipe() async throws {
        let r1 = try writeMates("S_R1.fastq", names: (1...200).map { "frag\($0)/1" })
        var names = (1...200).map { "frag\($0)/2" }
        names.swapAt(1, 2)
        let r2 = try writeMates("S_R2.fastq", names: names)

        for recipe in RecipeKind.allCases {
            let outcome = await importOutcome(recipe, r1: r1, r2: r2)
            XCTAssertEqual(outcome.words, Self.outOfStepWords, recipe.rawValue)
            XCTAssertEqual(outcome.startedAStep, false, recipe.rawValue)
            XCTAssertEqual(outcome.bundleExists, false, recipe.rawValue)
        }
    }

    /// Guard: an equal pair reaches the recipe's first step as before.
    func testAnEqualPairReachesTheFirstStepOfEveryRecipe() async throws {
        let r1 = try writeMates("S_R1.fastq", names: (1...200).map { "frag\($0)/1" })
        let r2 = try writeMates("S_R2.fastq", names: (1...200).map { "frag\($0)/2" })

        for recipe in RecipeKind.allCases {
            let outcome = await importOutcome(recipe, r1: r1, r2: r2)
            XCTAssertEqual(outcome.startedAStep, true, recipe.rawValue)
        }
    }

    // MARK: - Recipes

    /// Each recipe whose first step runs fastp on the loose pair.
    enum RecipeKind: String, CaseIterable {
        case fastpTrim = "new-format fastp-trim"
        case fastpDedup = "new-format fastp-dedup"
        case legacyQualityTrim = "old-format quality trim"
        case legacyAdapterTrim = "old-format adapter trim"
    }

    func config(_ recipe: RecipeKind, project: URL) -> FASTQBatchImporter.ImportConfig {
        func newFormat(_ type: String) -> Recipe {
            Recipe(id: "mates-\(type)", name: "Mates \(type)", requiredInput: .paired,
                   steps: [RecipeStep(type: type, label: type, params: nil)])
        }
        func oldFormat(_ step: FASTQDerivativeOperation) -> ProcessingRecipe {
            ProcessingRecipe(name: "Mates \(step.kind.rawValue)", steps: [step])
        }
        switch recipe {
        case .fastpTrim:
            return FASTQBatchImporter.ImportConfig(
                projectDirectory: project, platform: .illumina, newRecipe: newFormat(FastpTrimStep.typeID),
                qualityBinning: QualityBinningScheme.none, optimizeStorage: false, threads: 1)
        case .fastpDedup:
            return FASTQBatchImporter.ImportConfig(
                projectDirectory: project, platform: .illumina, newRecipe: newFormat(FastpDedupStep.typeID),
                qualityBinning: QualityBinningScheme.none, optimizeStorage: false, threads: 1)
        case .legacyQualityTrim:
            return FASTQBatchImporter.ImportConfig(
                projectDirectory: project, platform: .illumina,
                recipe: oldFormat(FASTQDerivativeOperation(
                    kind: .qualityTrim, createdAt: .distantPast, qualityThreshold: 20, windowSize: 4, qualityTrimMode: .cutRight)),
                qualityBinning: QualityBinningScheme.none, optimizeStorage: false, threads: 1)
        case .legacyAdapterTrim:
            return FASTQBatchImporter.ImportConfig(
                projectDirectory: project, platform: .illumina,
                recipe: oldFormat(FASTQDerivativeOperation(kind: .adapterTrim, createdAt: .distantPast)),
                qualityBinning: QualityBinningScheme.none, optimizeStorage: false, threads: 1)
        }
    }

    /// The failure words of one import of `r1` and `r2` with `recipe`, whether a step started, and whether a bundle was
    /// left.
    func importOutcome(_ recipe: RecipeKind, r1: URL, r2: URL) async -> (words: String?, startedAStep: Bool, bundleExists: Bool) {
        let project = root.appendingPathComponent("Project-\(UUID().uuidString).lungfish", isDirectory: true)
        let log = RecipeImportMateLog()
        let config = config(recipe, project: project)
        let result = await Task {
            await FASTQBatchImporter.runBatchImport(
                pairs: [SamplePair(sampleName: "S", r1: r1, r2: r2)], config: config, log: { log.observe($0) })
        }.value
        let bundle = project.appendingPathComponent("Imports/S.\(FASTQBundle.directoryExtension)")
        return (result.errors.first?.error, log.startedAStep, FileManager.default.fileExists(atPath: bundle.path))
    }

    func writeMates(_ name: String, names: [String]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(ReadSetFixtures.fastq(names).utf8).write(to: url)
        return url
    }
}
