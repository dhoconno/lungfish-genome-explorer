// RecipeImportMateCheckTests.swift - An import with a recipe refuses a loose R1 and R2 that do not pair before fastp runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// What one import logged: the name of each step that started.
private final class RecipeImportMateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []

    /// Records a step start and cancels the import's task right there, before the step launches its tool, so no
    /// fastp or clumpify runs at the base or after the fix (`NativeToolRunner.runProcess` checks for a cancel
    /// before it spawns).
    func observe(_ event: ImportLogEvent) {
        guard case .stepStart(_, let step, _, _) = event else { return }
        lock.withLock { steps.append(step) }
        withUnsafeCurrentTask { $0?.cancel() }
    }

    var startedAStep: Bool { lock.withLock { !steps.isEmpty } }
    var startedSteps: [String] { lock.withLock { steps } }
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

    // MARK: - No recipe (BIO-ROUTES-3 D1, S1)

    /// The words of the interleaver for two files out of step at record `record`, as an import throws them.
    static func outOfStepAtRecord(_ record: Int, r1Name: String, r2Name: String) -> String {
        "Paired FASTQ mates are out of step at record \(record): S_R1.fastq has '\(r1Name)' but S_R2.fastq has '\(r2Name)'. "
            + "The two files do not list the same fragments in the same order, so nothing was written."
    }

    /// The same words at record 1.
    static func outOfStepAtRecordOne(r1Name: String, r2Name: String) -> String {
        outOfStepAtRecord(1, r1Name: r1Name, r2Name: r2Name)
    }

    /// Six SRA-style names, both mates of one run carrying one serial and no mark.
    static func sraNames(_ serials: [Int]) -> [String] { serials.map { "SRR0000001.\($0) \($0) length=10" } }

    /// Red pin A. A default import (no recipe, no clumping, no binning) of two files with equal counts whose R2 is
    /// swapped at reads 3 and 4, in the SRA shape. No step starts and the import fails with the interleaver's words at
    /// record 3. The swap is not at reads 1 and 2, because the check reads the SRA spot names `x.1` and `x.2` as dotted
    /// mates, so a swap of spots 1 and 2 is named at record 2 (backlog S4).
    func testASwappedSRAR2IsRefusedWithNoRecipeBeforeAnyStep() async throws {
        let r1 = try writeMates("S_R1.fastq", names: Self.sraNames([1, 2, 3, 4, 5, 6]))
        let r2 = try writeMates("S_R2.fastq", names: Self.sraNames([1, 2, 4, 3, 5, 6]))

        let outcome = await plainImport(r1: r1, r2: r2)
        XCTAssertEqual(outcome.steps, [])
        XCTAssertEqual(
            outcome.words,
            Self.outOfStepAtRecord(3, r1Name: "SRR0000001.3 3 length=10", r2Name: "SRR0000001.4 4 length=10"))
    }

    /// Red pin B. The same pair with `/1` and `/2` marks.
    func testASwappedSlashMarkedR2IsRefusedWithNoRecipeBeforeAnyStep() async throws {
        let r1 = try writeMates("S_R1.fastq", names: [1, 2, 3, 4, 5, 6].map { "SRR0000001.\($0)/1" })
        let r2 = try writeMates("S_R2.fastq", names: [2, 1, 3, 4, 5, 6].map { "SRR0000001.\($0)/2" })

        let outcome = await plainImport(r1: r1, r2: r2)
        XCTAssertEqual(outcome.steps, [])
        XCTAssertEqual(outcome.words, Self.outOfStepAtRecordOne(r1Name: "SRR0000001.1/1", r2Name: "SRR0000001.2/2"))
    }

    /// Guard C. An in-step SRA pair, an `x.1` and `x.2` pair and a dotted `SRR1.7.1` and `SRR1.7.2` pair each reach the
    /// first step of a default import, so the check refuses no pair the recipe import accepts.
    func testAnInStepPairOfEachSRANameFamilyReachesTheFirstStepWithNoRecipe() async throws {
        let serials = [1, 2, 3, 4, 5, 6]
        let families: [(label: String, r1: [String], r2: [String])] = [
            ("SRA serial", Self.sraNames(serials), Self.sraNames(serials)),
            ("x.1 and x.2", serials.map { "frag\($0).1" }, serials.map { "frag\($0).2" }),
            ("dotted SRR1.7.1", serials.map { "SRR1.\($0).1" }, serials.map { "SRR1.\($0).2" }),
        ]
        for (index, family) in families.enumerated() {
            let r1 = try writeMates("F\(index)_R1.fastq", names: family.r1)
            let r2 = try writeMates("F\(index)_R2.fastq", names: family.r2)
            let firstStep = await plainImport(r1: r1, r2: r2).steps.first
            XCTAssertEqual(firstStep, "Compress", family.label)
        }
    }

    /// The default import: no recipe, no clumping and no binning, so the first step is "Compress".
    func plainImport(r1: URL, r2: URL) async -> (words: String?, steps: [String]) {
        let project = root.appendingPathComponent("Project-\(UUID().uuidString).lungfish", isDirectory: true)
        let log = RecipeImportMateLog()
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: project, platform: .illumina, recipe: nil,
            qualityBinning: QualityBinningScheme.none, optimizeStorage: false, threads: 1)
        let result = await Task {
            await FASTQBatchImporter.runBatchImport(
                pairs: [SamplePair(sampleName: "S", r1: r1, r2: r2)], config: config, log: { log.observe($0) })
        }.value
        return (result.errors.first?.error, log.startedSteps)
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
