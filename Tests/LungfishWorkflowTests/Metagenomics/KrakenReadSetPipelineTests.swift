// KrakenReadSetPipelineTests.swift - Kraken2 classifies pairs as pairs and single reads beside them in one run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// Owner decisions 1 and 2 (2026-10-03, docs/contracts/READ-PAIRING.md) for
/// Kraken2: a paired derivative runs `--paired R1 R2`, a merge or repair
/// derivative runs its pair with each file of single reads beside it and a
/// staged header-only mate, and single-end input keeps today's command. A
/// stand-in kraken2 records its argv and keeps a copy of each input.
final class KrakenReadSetPipelineTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken-read-set")
        fixtures = try ReadSetFixtures(in: root)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Planner

    func testSingleReadsKeepTodaysConfig() async throws {
        for bundle in [fixtures.singleRoot, fixtures.chunkedRoot, fixtures.fastaDerivative, fixtures.fullDerivative] {
            var config = makeConfig(inputFiles: [bundle])
            let before = config
            let plan = try await KrakenReadSetPlanner.plan(
                bundle: bundle,
                materializedInputs: [],
                materializationDirectory: root.appendingPathComponent("inputs-\(UUID().uuidString)")
            )
            XCTAssertFalse(try KrakenReadSetPlanner.apply(plan, to: &config), bundle.lastPathComponent)
            XCTAssertEqual(config, before, "\(bundle.lastPathComponent) keeps today's config")
            XCTAssertNil(config.fragmentComposition)
        }
    }

    func testPairedDerivativeRunsAsOnePair() async throws {
        let config = try await planned(fixtures.pairedDerivative)
        XCTAssertTrue(config.isPairedEnd)
        XCTAssertFalse(config.interleavedInput)
        XCTAssertEqual(config.inputFiles.map(\.lastPathComponent), ["sample_R1.fastq", "sample_R2.fastq"])
        XCTAssertEqual(config.singleReadFiles, [])
        XCTAssertTrue(config.plansReadSet)
        XCTAssertEqual(config.fragmentComposition, ClassificationFragmentComposition(
            pairedFragments: 2, mergedReads: 0, orphanReads: 0, singleEndReads: 0
        ))
    }

    func testMergeAndRepairDerivativesRunTheirPairWithSingleReadsBeside() async throws {
        let merge = try await planned(fixtures.mergeDerivative)
        XCTAssertEqual(merge.inputFiles.map(\.lastPathComponent), ["unmerged_R1.fastq", "unmerged_R2.fastq"])
        XCTAssertEqual(merge.singleReadFiles.map(\.lastPathComponent), ["merged.fastq"])
        XCTAssertEqual(merge.fragmentComposition?.pairedFragments, 1)
        XCTAssertEqual(merge.fragmentComposition?.mergedReads, 3)

        let repair = try await planned(fixtures.repairDerivative)
        XCTAssertEqual(repair.inputFiles.map(\.lastPathComponent), ["repaired_R1.fastq", "repaired_R2.fastq"])
        XCTAssertEqual(repair.singleReadFiles.map(\.lastPathComponent), ["singletons.fastq"])
        XCTAssertEqual(repair.fragmentComposition?.orphanReads, 1)
        XCTAssertEqual(repair.fragmentComposition?.fragmentCount, 3)
    }

    func testMixedRootFileIsSplitByNameThenRunsAsPairAndSingleReads() async throws {
        let inputs = root.appendingPathComponent("split", isDirectory: true)
        let config = try await planned(fixtures.mixedRoot, materializationDirectory: inputs)
        XCTAssertTrue(config.isPairedEnd)
        XCTAssertEqual(try config.inputFiles.map(ReadSetFixtures.readNames(in:)), [["p1/1", "p2/1"], ["p1/2", "p2/2"]])
        XCTAssertEqual(try config.singleReadFiles.map(ReadSetFixtures.readNames(in:)), [["m1", "m2", "m3"]])
        XCTAssertTrue(config.inputFiles.allSatisfy { $0.path.hasPrefix(inputs.standardizedFileURL.path) })
        XCTAssertEqual(config.readSetPlan?.steps.map(\.kind), [.splitByName])
        XCTAssertEqual(config.fragmentComposition?.fragmentCount, 5)
    }

    func testInterleavedRootKeepsThePositionalSplit() async throws {
        var config = makeConfig(inputFiles: [fixtures.interleavedRoot])
        config.interleavedInput = true
        let file = fixtures.interleavedRoot.appendingPathComponent("reads.fastq").standardizedFileURL
        config.inputFiles = [file]
        let plan = try await KrakenReadSetPlanner.plan(
            bundle: fixtures.interleavedRoot, materializedInputs: [file],
            materializationDirectory: root.appendingPathComponent("inputs")
        )
        XCTAssertFalse(try KrakenReadSetPlanner.apply(plan, to: &config))
        XCTAssertTrue(config.interleavedInput)
        XCTAssertFalse(config.isPairedEnd)
        XCTAssertEqual(config.inputFiles, [file])
        XCTAssertFalse(config.plansReadSet)
    }

    /// Final review N3. kraken2 splits an interleaved file by position and
    /// reads it alone, so no file of single reads can run beside it. A plan
    /// that ever held both stops the run rather than leave the single reads out.
    func testAnInterleavedPairWithSingleReadsStopsRatherThanDropThem() throws {
        let interleaved = fixtures.interleavedRoot.appendingPathComponent("reads.fastq").standardizedFileURL
        let merged = fixtures.mergeDerivative.appendingPathComponent("merged.fastq").standardizedFileURL
        let runs = [ReadSetRun(
            matePairs: [ReadSetMatePair(files: .interleaved(interleaved), pairCount: 2)],
            singleReads: [ReadSetSingleReads(url: merged, role: .merged, readCount: 3)]
        )]
        let plan = ReadSetPlan(
            inputURL: interleaved, capability: KrakenReadSetPlanner.capability,
            sourceLayout: .pairedFilesWithSingleReads, layoutReason: "An interleaved pair beside merged reads.",
            sequencingPlatform: nil, wasMaterialized: false, sampleHoldsPairsAndSingleReads: true,
            runs: runs, steps: [], singleReadReason: nil, composition: ReadSetComposition(runs: runs)
        )
        var config = makeConfig(inputFiles: [interleaved])
        let before = config
        XCTAssertThrowsError(try KrakenReadSetPlanner.apply(plan, to: &config), "the single reads would be left out")
        XCTAssertEqual(config, before, "the config is left as it was")
    }

    func testVirtualSubsetIsPlannedFromItsMaterializedFile() async throws {
        let materialized = root.appendingPathComponent("materialized.fastq")
        try ReadSetFixtures.fastq(["u1/1", "u1/2", "x1"]).write(to: materialized, atomically: true, encoding: .utf8)
        let config = try await planned(fixtures.subsetOfMerge, materializedInputs: [materialized])
        XCTAssertTrue(config.isPairedEnd)
        XCTAssertEqual(try config.singleReadFiles.map(ReadSetFixtures.readNames(in:)), [["x1"]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: materialized.path), "the materialization is kept")
    }

    /// Lead A F4. A plan of single reads applies nothing, so it never reads
    /// its files a second time to count them. A plan that holds pairs counts
    /// the files whose counts it lacks, exactly, for the guard and the result.
    func testOnlyAPlanWithPairsIsCounted() async throws {
        let loose = root.appendingPathComponent("loose-single.fastq")
        try ReadSetFixtures.fastq(["a", "b", "c"]).write(to: loose, atomically: true, encoding: .utf8)
        for input in [loose, fixtures.singleRoot, fixtures.chunkedRoot] {
            let plan = try await KrakenReadSetPlanner.plan(
                bundle: input, materializedInputs: [],
                materializationDirectory: root.appendingPathComponent("inputs-\(UUID().uuidString)")
            )
            XCTAssertNil(plan.composition.singleEndReads, "\(input.lastPathComponent) is not counted")
            XCTAssertTrue(plan.singleReads.allSatisfy { $0.readCount == nil }, input.lastPathComponent)
        }

        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/read-pairing/kraken2", isDirectory: true)
        let r1 = fixture.appendingPathComponent("unmerged_R1.fastq")
        let r2 = fixture.appendingPathComponent("unmerged_R2.fastq")
        let merged = fixture.appendingPathComponent("merged.fastq")

        // A paired derivative records no counts, so its pairs are counted.
        let paired = fixtures.importsURL.appendingPathComponent("fixture-paired.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: paired, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: r1, to: paired.appendingPathComponent("unmerged_R1.fastq"))
        try FileManager.default.copyItem(at: r2, to: paired.appendingPathComponent("unmerged_R2.fastq"))
        let operation = FASTQDerivativeOperation(kind: .interleaveReformat)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "fixture-paired", parentBundleRelativePath: ".", rootBundleRelativePath: ".",
                rootFASTQFilename: "unmerged_R1.fastq",
                payload: .fullPaired(r1Filename: "unmerged_R1.fastq", r2Filename: "unmerged_R2.fastq"),
                lineage: [operation], operation: operation,
                cachedStatistics: .placeholder(readCount: 46, baseCount: 1), pairingMode: .pairedEnd, sequenceFormat: .fastq
            ),
            in: paired
        )
        let pairedPlan = try await KrakenReadSetPlanner.plan(
            bundle: paired, materializedInputs: [], materializationDirectory: root.appendingPathComponent("paired-inputs")
        )
        XCTAssertEqual(ClassificationFragmentComposition(pairedPlan.composition),
                       ClassificationFragmentComposition(pairedFragments: 23, mergedReads: 0, orphanReads: 0, singleEndReads: 0))

        // A loose file of the merged reads then the pairs, interleaved, is split and counted.
        let mixed = root.appendingPathComponent("merged-then-pairs.fastq")
        let mates = zip(try fastqRecords(r1), try fastqRecords(r2)).flatMap { [$0, $1] }
        try (try fastqRecords(merged) + mates).joined().write(to: mixed, atomically: true, encoding: .utf8)
        let mixedPlan = try await KrakenReadSetPlanner.plan(
            bundle: mixed, materializedInputs: [], materializationDirectory: root.appendingPathComponent("mixed-inputs")
        )
        let composition = try XCTUnwrap(ClassificationFragmentComposition(mixedPlan.composition))
        XCTAssertEqual(composition.pairedFragments, 23)
        XCTAssertEqual(composition.singleReadFragments, 77)

        // Loose files named as a pair with --unpaired are counted too.
        let loosePlan = try KrakenReadSetPlanner.plan(
            r1: r1, r2: r2, singleReads: [merged], materializationDirectory: root.appendingPathComponent("loose-inputs")
        )
        XCTAssertEqual(ClassificationFragmentComposition(loosePlan.composition)?.fragmentCount, 100)
    }

    /// The four-line records of a FASTQ file, each with its newlines.
    private func fastqRecords(_ url: URL) throws -> [String] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        return stride(from: 0, to: lines.count - 3, by: 4).map { lines[$0..<$0 + 4].joined(separator: "\n") + "\n" }
    }

    func testPreviewReadsOnlyMetadata() async {
        let cases: [(URL, KrakenReadSetPreview)] = [
            (fixtures.singleRoot, .singleReads),
            (fixtures.interleavedRoot, .interleavedPairs),
            (fixtures.mixedRoot, .pairs(withSingleReads: true)),
            (fixtures.pairedDerivative, .pairs(withSingleReads: false)),
            (fixtures.mergeDerivative, .pairs(withSingleReads: true)),
            (fixtures.repairDerivative, .pairs(withSingleReads: true)),
            (fixtures.subsetOfSingle, .singleReads),
            (fixtures.subsetOfMerge, .decidedAtRunTime),
            (fixtures.subsetOfInterleaved, .decidedAtRunTime),
        ]
        for (bundle, expected) in cases {
            let preview = await KrakenReadSetPlanner.preview(bundle: bundle)
            XCTAssertEqual(preview, expected, bundle.lastPathComponent)
        }
    }

    func testKraken2IsTheAdoptedConsumer() {
        XCTAssertEqual(ReadPairingCapabilityRegistry.declaration(for: "classify.kraken2")?.adopted, true)
        XCTAssertEqual(KrakenReadSetPlanner.capability, .bothInOneRunAsSeparateFiles)
    }

    // MARK: - Pipeline with a stand-in kraken2

    func testSingleEndArgvIsUnchanged() async throws {
        let kraken2 = try StandInKraken2(root: root.appendingPathComponent("single-run"))
        let file = fixtures.singleRoot.appendingPathComponent("single.fastq")
        var config = makeConfig(inputFiles: [file], database: kraken2.databaseURL)
        config.originalInputFiles = [fixtures.singleRoot]
        _ = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)
        XCTAssertEqual(try kraken2.argv(), Array(config.kraken2Arguments()))
        XCTAssertFalse(try kraken2.argv().contains("--paired"))
        let sidecar = try String(contentsOf: config.outputDirectory.appendingPathComponent("classification-result.json"), encoding: .utf8)
        for key in ["singleReadFiles", "plansReadSet", "fragmentComposition", "readPairingContract"] {
            XCTAssertFalse(sidecar.contains(key), "a single-end sidecar has no \(key)")
        }
    }

    func testMergeDerivativeRunsOneKraken2WithStagedEmptyMates() async throws {
        let kraken2 = try StandInKraken2(root: root.appendingPathComponent("merge-run"))
        var config = try await planned(fixtures.mergeDerivative, database: kraken2.databaseURL)
        config.originalInputFiles = [fixtures.mergeDerivative]
        let result = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)

        let merged = fixtures.mergeDerivative.appendingPathComponent("merged.fastq").standardizedFileURL
        let mate = config.emptyMateURL(for: merged)
        let argv = try kraken2.argv()
        XCTAssertEqual(Array(argv.suffix(4)), [
            config.inputFiles[0].path, config.inputFiles[1].path, merged.path, mate.path,
        ])
        XCTAssertTrue(argv.contains("--paired"))

        // Staging content: the same headers in the same order, empty sequence and quality.
        let seenMate = try kraken2.inputsSeen()[3]
        XCTAssertEqual(try String(contentsOf: seenMate, encoding: .utf8), "@x1\n\n+\n\n@x2\n\n+\n\n@x3\n\n+\n\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mate.path), "the staged mate is removed after the run")

        // Provenance records the staging step and its counts, and kraken2 depends on it.
        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: config.outputDirectory))
        let staging = try XCTUnwrap(provenance.steps.first { $0.toolName == ClassificationPipeline.singleReadMateStagingToolName })
        XCTAssertEqual(staging.resolvedOptions?["records"], .integer(3))
        XCTAssertEqual(staging.inputs.map(\.path), [merged.path])
        XCTAssertEqual(staging.outputs.map(\.path), [mate.path])
        let kraken = try XCTUnwrap(provenance.steps.first { $0.toolName == "kraken2" })
        XCTAssertTrue(kraken.dependsOn.contains(staging.id))
        XCTAssertTrue(kraken.inputs.map(\.path).contains(merged.path))

        // The result counts fragments and records the contract.
        XCTAssertEqual(result.fragmentComposition?.pairedFragments, 1)
        XCTAssertEqual(result.fragmentComposition?.mergedReads, 3)
        XCTAssertEqual(result.readPairingContract, 1)
        let reloaded = try ClassificationResult.load(from: config.outputDirectory)
        XCTAssertEqual(reloaded.fragmentComposition, result.fragmentComposition)
        XCTAssertEqual(reloaded.readPairingContract, 1)
        XCTAssertEqual(reloaded.config.singleReadFiles, [merged])
    }

    func testPairedDerivativeRunsPairedWithNoStaging() async throws {
        let kraken2 = try StandInKraken2(root: root.appendingPathComponent("paired-run"))
        var config = try await planned(fixtures.pairedDerivative, database: kraken2.databaseURL)
        config.originalInputFiles = [fixtures.pairedDerivative]
        let result = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)
        let argv = try kraken2.argv()
        XCTAssertTrue(argv.contains("--paired"))
        XCTAssertEqual(Array(argv.suffix(2)), config.inputFiles.map(\.path))
        XCTAssertEqual(result.fragmentComposition?.fragmentCount, 2)
        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: config.outputDirectory))
        XCTAssertFalse(provenance.steps.contains { $0.toolName == ClassificationPipeline.singleReadMateStagingToolName })
    }

    func testMixedRootRecordsTheSplitStep() async throws {
        let kraken2 = try StandInKraken2(root: root.appendingPathComponent("mixed-run"))
        var config = try await planned(fixtures.mixedRoot, database: kraken2.databaseURL)
        config.originalInputFiles = [fixtures.mixedRoot]
        _ = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)
        let seen = try kraken2.inputsSeen().map(ReadSetFixtures.readNames(in:))
        XCTAssertEqual(Array(seen.prefix(3)), [["p1/1", "p2/1"], ["p1/2", "p2/2"], ["m1", "m2", "m3"]])
        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: config.outputDirectory))
        let split = try XCTUnwrap(provenance.steps.first { $0.toolName == "Lungfish Read-Set Split" })
        XCTAssertEqual(split.resolvedOptions?["pairs"], .integer(2))
        XCTAssertEqual(split.resolvedOptions?["singleReads"], .integer(3))
    }

    func testAKraken2ThatDropsAFragmentFailsTheRun() async throws {
        let kraken2 = try StandInKraken2(root: root.appendingPathComponent("drop-run"), dropOneLine: true)
        var config = try await planned(fixtures.mergeDerivative, database: kraken2.databaseURL)
        config.originalInputFiles = [fixtures.mergeDerivative]
        do {
            _ = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)
            XCTFail("a per-read output one line short must fail the run")
        } catch let error as KrakenFragmentGuardError {
            XCTAssertEqual(error, .perReadLineCountDiffers(expected: 4, lines: 3))
            XCTAssertTrue(error.localizedDescription.contains("per-read output has 3 lines"))
        }
        XCTAssertFalse(ClassificationResult.exists(in: config.outputDirectory))
    }

    func testAKraken2ThatMiscountsSequencesFailsTheRun() async throws {
        let kraken2 = try StandInKraken2(root: root.appendingPathComponent("miscount-run"), misreportProcessed: true)
        var config = try await planned(fixtures.pairedDerivative, database: kraken2.databaseURL)
        config.originalInputFiles = [fixtures.pairedDerivative]
        do {
            _ = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)
            XCTFail("a wrong processed count must fail the run")
        } catch let error as KrakenFragmentGuardError {
            XCTAssertEqual(error, .processedCountDiffers(expected: 2, reported: 3))
        }
    }

    func testAQuietKraken2IsCheckedByItsPerReadLinesAlone() async throws {
        // `--extra-args "--quiet"` suppresses the processed-count summary.
        let kraken2 = try StandInKraken2(root: root.appendingPathComponent("quiet-run"), printsSummary: false)
        var config = try await planned(fixtures.mergeDerivative, database: kraken2.databaseURL)
        config.originalInputFiles = [fixtures.mergeDerivative]
        let result = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)
        XCTAssertEqual(result.fragmentComposition?.fragmentCount, 4)

        let dropping = try StandInKraken2(root: root.appendingPathComponent("quiet-drop-run"), dropOneLine: true, printsSummary: false)
        var dropped = try await planned(fixtures.mergeDerivative, database: dropping.databaseURL)
        dropped.originalInputFiles = [fixtures.mergeDerivative]
        do {
            _ = try await ClassificationPipeline(condaManager: dropping.condaManager).classify(config: dropped)
            XCTFail("the per-read line count is still checked")
        } catch let error as KrakenFragmentGuardError {
            XCTAssertEqual(error, .perReadLineCountDiffers(expected: 4, lines: 3))
        }
    }

    // MARK: - Codable

    func testEveryCommittedKraken2SidecarLoadsUnchanged() throws {
        let fixturesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        let directories = [
            "kraken2-mini/SRR35517702", "kraken2-mini/SRR35517703", "kraken2-mini/SRR35517705",
            "kraken2-bracken-reopen", "analyses/kraken2-2026-01-15T11-00-00",
        ].map { fixturesRoot.appendingPathComponent($0, isDirectory: true) }
        for directory in directories {
            let data = try Data(contentsOf: directory.appendingPathComponent(ClassificationResult.sidecarFilename))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let sidecar = try decoder.decode(PersistedClassificationResult.self, from: data)
            XCTAssertNil(sidecar.fragmentComposition, directory.lastPathComponent)
            XCTAssertNil(sidecar.readPairingContract, directory.lastPathComponent)
            XCTAssertEqual(sidecar.config.singleReadFiles, [], directory.lastPathComponent)
            XCTAssertFalse(sidecar.config.plansReadSet, directory.lastPathComponent)
            let encoded = try String(decoding: JSONEncoder().encode(sidecar.config), as: UTF8.self)
            XCTAssertFalse(encoded.contains("singleReadFiles"), directory.lastPathComponent)
            XCTAssertFalse(encoded.contains("plansReadSet"), directory.lastPathComponent)
            XCTAssertNoThrow(try ClassificationResult.load(from: directory), directory.lastPathComponent)
        }
    }

    func testFragmentCompositionRoundTrips() throws {
        let composition = ClassificationFragmentComposition(
            pairedFragments: 23, mergedReads: 77, orphanReads: 0, singleEndReads: 0, mergedOrOrphanReads: 4
        )
        let data = try JSONEncoder().encode(composition)
        XCTAssertEqual(try JSONDecoder().decode(ClassificationFragmentComposition.self, from: data), composition)
        XCTAssertEqual(composition.fragmentCount, 104)
        XCTAssertEqual(composition.summaryLine, "104 fragments, 23 from read pairs and 81 from merged or single reads")
        let noMixed = ClassificationFragmentComposition(pairedFragments: 1, mergedReads: 2, orphanReads: 0, singleEndReads: 0)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(noMixed), as: UTF8.self).contains("mergedOrOrphanReads"))
    }

    // MARK: - Helpers

    private func makeConfig(inputFiles: [URL], database: URL? = nil) -> ClassificationConfig {
        let databaseURL = database ?? root.appendingPathComponent("db", isDirectory: true)
        return ClassificationConfig(
            inputFiles: inputFiles,
            isPairedEnd: false,
            databaseName: "FixtureDB",
            databasePath: databaseURL,
            outputDirectory: root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        )
    }

    /// A config for `bundle` from its read-set plan, as the CLI and the app make it.
    private func planned(
        _ bundle: URL,
        materializedInputs: [URL] = [],
        materializationDirectory: URL? = nil,
        database: URL? = nil
    ) async throws -> ClassificationConfig {
        var config = makeConfig(inputFiles: [bundle], database: database)
        let plan = try await KrakenReadSetPlanner.plan(
            bundle: bundle,
            materializedInputs: materializedInputs,
            materializationDirectory: materializationDirectory
                ?? config.outputDirectory.appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName)
        )
        XCTAssertTrue(try KrakenReadSetPlanner.apply(plan, to: &config), bundle.lastPathComponent)
        return config
    }
}

/// A conda root whose stand-in micromamba runs a stand-in kraken2. It records
/// its argv one argument per line, keeps a copy of each input, writes one
/// per-read line per fragment and reports kraken2's processed count.
struct StandInKraken2 {
    let condaManager: CondaManager
    let databaseURL: URL
    let seenDirectory: URL

    init(root: URL, dropOneLine: Bool = false, misreportProcessed: Bool = false, printsSummary: Bool = true) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("kraken-db", isDirectory: true)
        try fm.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        for filename in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try "fake-db\n".write(to: databaseURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        seenDirectory = root.appendingPathComponent("kraken2-saw", isDirectory: true)
        let micromamba = root.appendingPathComponent("stand-in-micromamba")
        try Self.script(seen: seenDirectory, drop: dropOneLine, misreport: misreportProcessed, summary: printsSummary)
            .write(to: micromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    func argv() throws -> [String] {
        try String(contentsOf: seenDirectory.appendingPathComponent("argv"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func inputsSeen() throws -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: seenDirectory.path)) ?? []
        return names.filter { $0.hasPrefix("input-") }
            .sorted { (Int($0.dropFirst(6)) ?? 0) < (Int($1.dropFirst(6)) ?? 0) }
            .map { seenDirectory.appendingPathComponent($0) }
    }

    private static func script(seen: URL, drop: Bool, misreport: Bool, summary: Bool) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "micromamba 2.0.0"; exit 0; fi
        [ "$1" = "run" ] || { echo "unexpected micromamba invocation: $*" >&2; exit 64; }
        shift
        if [ "$1" = "-n" ]; then shift; shift; fi
        tool="$1"; shift
        [ "$tool" = "kraken2" ] || { echo "unexpected tool: $tool" >&2; exit 64; }
        if [ "$1" = "--version" ]; then echo "Kraken version 2.1.3"; exit 0; fi
        seen='\(seen.path)'
        mkdir -p "$seen"
        : > "$seen/argv"
        for arg in "$@"; do printf '%s\\n' "$arg" >> "$seen/argv"; done
        report=""; output=""; paired=0; index=0; files=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --db|--threads|--confidence|--minimum-hit-groups) shift ;;
            --report) shift; report="$1" ;;
            --output) shift; output="$1" ;;
            --paired) paired=1 ;;
            --*) ;;
            *) index=$((index + 1)); cp "$1" "$seen/input-$index"; files="$files $1" ;;
          esac
          shift
        done
        total=0; position=0
        for f in $files; do
          position=$((position + 1))
          if [ "$paired" = 1 ] && [ $((position % 2)) = 0 ]; then continue; fi
          n=$(awk 'END { print int(NR / 4) }' "$f")
          total=$((total + n))
        done
        lines=\(drop ? "$((total - 1))" : "$total")
        processed=\(misreport ? "$((total + 1))" : "$total")
        mkdir -p "$(dirname "$report")" "$(dirname "$output")"
        printf '100.00\\t1\\t0\\tR\\t1\\troot\\n100.00\\t1\\t1\\tS\\t562\\t  Escherichia coli\\n' > "$report"
        : > "$output"
        i=0
        while [ "$i" -lt "$lines" ]; do printf 'C\\tread%s\\t562\\t4\\t0:4\\n' "$i" >> "$output"; i=$((i + 1)); done
        \(summary ? "" : ": ")echo "$processed sequences (0.00 Mbp) processed in 0.001s (1.0 Kseq/m, 0.01 Mbp/m)." >&2
        exit 0
        """
    }
}
