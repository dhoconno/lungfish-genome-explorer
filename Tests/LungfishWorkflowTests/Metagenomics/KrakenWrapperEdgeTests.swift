// KrakenWrapperEdgeTests.swift - Kraken2 runs whose inputs meet the kraken2 wrapper's edges
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.1 lane L6, item 2. The pinned kraken2 2.17.1 wrapper reads the
// compression of its first input, R1, and pipes every input through that
// decompressor. With R1 gzip and R2 plain, kraken2 reads R2 as empty and
// classifies nothing. With R1 plain and R2 gzip, it reads the gzip bytes as
// one read. It exits 0 both times. The kraken2 step's replay argv also named
// files the run stages and then deletes.

import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

final class KrakenWrapperEdgeTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken-wrapper-edges")
        fixtures = try ReadSetFixtures(in: root)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - R1 and R2 of mixed compression

    func testR1AndR2OfMixedCompressionReachKraken2InTheCompressionOfR1() async throws {
        let pair = try loosePair()
        for r1IsGzip in [true, false] {
            let label = r1IsGzip ? "gzip R1, plain R2" : "plain R1, gzip R2"
            let kraken2 = try StandInKraken2(root: root.appendingPathComponent("mixed-\(r1IsGzip)"))
            let r1 = r1IsGzip ? pair.gzipR1 : pair.plainR1
            let r2 = r1IsGzip ? pair.plainR2 : pair.gzipR2
            var config = makeConfig(inputFiles: [r1, r2], database: kraken2.databaseURL)
            config.isPairedEnd = true
            config.originalInputFiles = [r1, r2]

            let result = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)

            let seen = try kraken2.inputsSeen()
            XCTAssertEqual(seen.map(Self.isGzip), [r1IsGzip, r1IsGzip], "\(label): both mates in the compression of R1")
            XCTAssertEqual(try Self.plainText(of: seen[1]), ReadSetFixtures.fastq(["q1/2", "q2/2"]), "\(label): R2 unchanged")
            XCTAssertEqual(try ClassificationPipeline.lineCount(of: result.outputURL), 2, "\(label): kraken2 classifies both pairs")
            XCTAssertEqual(stagedInputs(of: config), [], "\(label): the staged copy is removed after the run")

            let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: config.outputDirectory))
            let staging = try XCTUnwrap(
                provenance.steps.first { $0.toolName == ClassificationPipeline.inputCompressionStagingToolName },
                "\(label): the copy is recorded"
            )
            XCTAssertEqual(staging.inputs.map(\.path), [r2.path], label)
            let kraken = try XCTUnwrap(provenance.steps.first { $0.toolName == "kraken2" })
            XCTAssertTrue(kraken.dependsOn.contains(staging.id), label)
            XCTAssertEqual(result.config.inputFiles, [r1, r2], "\(label): the result names the files the user gave")
        }
    }

    func testR1AndR2OfMixedCompressionWithSingleReadsBesideThem() async throws {
        let pair = try loosePair()
        let merged = root.appendingPathComponent("loose/s_merged.fastq")
        try ReadSetFixtures.fastq(["y1", "y2", "y3"]).write(to: merged, atomically: true, encoding: .utf8)
        for r1IsGzip in [true, false] {
            let label = r1IsGzip ? "gzip R1, plain R2" : "plain R1, gzip R2"
            let kraken2 = try StandInKraken2(root: root.appendingPathComponent("mixed-singles-\(r1IsGzip)"))
            let r1 = r1IsGzip ? pair.gzipR1 : pair.plainR1
            let r2 = r1IsGzip ? pair.plainR2 : pair.gzipR2
            var config = makeConfig(inputFiles: [r1, r2], database: kraken2.databaseURL)
            config.isPairedEnd = true
            config.originalInputFiles = [r1, r2]
            let plan = try KrakenReadSetPlanner.plan(
                r1: r1, r2: r2, singleReads: [merged],
                materializationDirectory: config.outputDirectory.appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName)
            )
            XCTAssertTrue(try KrakenReadSetPlanner.apply(plan, to: &config, recordedWithAuto: false), label)

            let result = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)

            XCTAssertEqual(result.fragmentComposition?.fragmentCount, 5, label)
            XCTAssertEqual(try kraken2.inputsSeen().map(Self.isGzip), Array(repeating: r1IsGzip, count: 4), "\(label): every input in the compression of R1")
            XCTAssertEqual(stagedInputs(of: config), [], "\(label): every staged file is removed")
        }
    }

    /// The wrapper's rule is the same for single-end files, so a file in the
    /// other compression than the first one is read from a staged copy too.
    func testSingleEndFilesOfMixedCompressionReachKraken2InTheCompressionOfTheFirst() async throws {
        let pair = try loosePair()
        let kraken2 = try StandInKraken2(root: root.appendingPathComponent("mixed-single-end"))
        var config = makeConfig(inputFiles: [pair.gzipR1, pair.plainR2], database: kraken2.databaseURL)
        config.originalInputFiles = [pair.gzipR1, pair.plainR2]

        let result = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)

        XCTAssertFalse(try kraken2.argv().contains("--paired"))
        XCTAssertEqual(try kraken2.inputsSeen().map(Self.isGzip), [true, true])
        XCTAssertEqual(try ClassificationPipeline.lineCount(of: result.outputURL), 4, "every read of both files")
        XCTAssertEqual(stagedInputs(of: config), [])
    }

    /// Files that share R1's compression stage nothing, and their kraken2
    /// command stays byte for byte.
    func testR1AndR2OfOneCompressionStageNothing() async throws {
        let pair = try loosePair()
        for (r1, r2) in [(pair.plainR1, pair.plainR2), (pair.gzipR1, pair.gzipR2)] {
            let kraken2 = try StandInKraken2(root: root.appendingPathComponent("same-\(r1.pathExtension)"))
            var config = makeConfig(inputFiles: [r1, r2], database: kraken2.databaseURL)
            config.isPairedEnd = true
            _ = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)
            XCTAssertEqual(Array(try kraken2.argv().suffix(2)), [r1.path, r2.path])
            let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: config.outputDirectory))
            XCTAssertFalse(provenance.steps.contains { $0.toolName == ClassificationPipeline.inputCompressionStagingToolName })
        }
    }

    // MARK: - The kraken2 step's replay argv

    /// A durable replay argv names only files that outlive the run. A run that
    /// stages a file for kraken2 and deletes it afterwards, the header-only
    /// mates, a copy in R1's compression or the halves of an interleaved
    /// file, has no kraken2 command over durable files, so the step records
    /// none. Its argv still records what ran, and the run's recorded command
    /// reproduces it.
    func testTheKraken2StepRecordsNoReplayArgvNamingFilesTheRunDeletes() async throws {
        let pair = try loosePair()
        var runs: [(label: String, config: ClassificationConfig, kraken2: StandInKraken2)] = []

        let stagedKraken2 = try StandInKraken2(root: root.appendingPathComponent("replay-staged"))
        var staged = try await planned(fixtures.mergeDerivative, database: stagedKraken2.databaseURL)
        staged.originalInputFiles = [fixtures.mergeDerivative]
        runs.append(("staged single reads", staged, stagedKraken2))

        let interleavedKraken2 = try StandInKraken2(root: root.appendingPathComponent("replay-interleaved"))
        var interleaved = makeConfig(
            inputFiles: [fixtures.interleavedRoot.appendingPathComponent("reads.fastq")],
            database: interleavedKraken2.databaseURL
        )
        interleaved.interleavedInput = true
        runs.append(("interleaved split", interleaved, interleavedKraken2))

        let mixedKraken2 = try StandInKraken2(root: root.appendingPathComponent("replay-mixed"))
        var mixed = makeConfig(inputFiles: [pair.gzipR1, pair.plainR2], database: mixedKraken2.databaseURL)
        mixed.isPairedEnd = true
        runs.append(("R2 copy in R1's compression", mixed, mixedKraken2))

        for run in runs {
            _ = try await ClassificationPipeline(condaManager: run.kraken2.condaManager).classify(config: run.config)
            let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: run.config.outputDirectory))
            let kraken = try XCTUnwrap(provenance.steps.first { $0.toolName == "kraken2" })
            let gone = kraken.command.filter { $0.hasPrefix("/") && !FileManager.default.fileExists(atPath: $0) }
            XCTAssertFalse(gone.isEmpty, "\(run.label): the run deletes a file kraken2 read (\(kraken.command))")
            XCTAssertNil(kraken.durableReplayArgv, "\(run.label): no durable replay over files the run deleted")
        }
    }

    /// Runs that stage nothing keep the durable replay argv they recorded.
    func testRunsThatStageNothingKeepTheirReplayArgv() async throws {
        let pair = try loosePair()
        let kraken2 = try StandInKraken2(root: root.appendingPathComponent("replay-plain"))
        var config = makeConfig(inputFiles: [pair.plainR1, pair.plainR2], database: kraken2.databaseURL)
        config.isPairedEnd = true
        _ = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)
        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: config.outputDirectory))
        let kraken = try XCTUnwrap(provenance.steps.first { $0.toolName == "kraken2" })
        XCTAssertEqual(kraken.durableReplayArgv, kraken.command)
    }

    // MARK: - Helpers

    private struct LoosePair {
        let plainR1: URL
        let plainR2: URL
        let gzipR1: URL
        let gzipR2: URL
    }

    private func loosePair() throws -> LoosePair {
        let loose = root.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        let plainR1 = loose.appendingPathComponent("s_R1.fastq")
        let plainR2 = loose.appendingPathComponent("s_R2.fastq")
        if !FileManager.default.fileExists(atPath: plainR1.path) {
            try ReadSetFixtures.fastq(["q1/1", "q2/1"]).write(to: plainR1, atomically: true, encoding: .utf8)
            try ReadSetFixtures.fastq(["q1/2", "q2/2"]).write(to: plainR2, atomically: true, encoding: .utf8)
        }
        return LoosePair(
            plainR1: plainR1,
            plainR2: plainR2,
            gzipR1: try gzipCopy(of: plainR1, into: root.appendingPathComponent("gzip", isDirectory: true)),
            gzipR2: try gzipCopy(of: plainR2, into: root.appendingPathComponent("gzip", isDirectory: true))
        )
    }

    private func makeConfig(inputFiles: [URL], database: URL) -> ClassificationConfig {
        ClassificationConfig(
            inputFiles: inputFiles,
            isPairedEnd: false,
            databaseName: "FixtureDB",
            databasePath: database,
            outputDirectory: root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func planned(_ bundle: URL, database: URL) async throws -> ClassificationConfig {
        var config = makeConfig(inputFiles: [bundle], database: database)
        let plan = try await KrakenReadSetPlanner.plan(
            bundle: bundle,
            materializedInputs: [],
            materializationDirectory: config.outputDirectory.appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName)
        )
        XCTAssertTrue(try KrakenReadSetPlanner.apply(plan, to: &config), bundle.lastPathComponent)
        return config
    }

    private func stagedInputs(of config: ClassificationConfig) -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: config.outputDirectory.appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName).path
        )) ?? []
    }

    private func gzipCopy(of file: URL, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(file.lastPathComponent + ".gz")
        if !FileManager.default.fileExists(atPath: output.path) {
            _ = try gzipCompressFASTQ(sourceURL: file, outputURL: output, failureDescription: "the test copy of")
        }
        return output
    }

    static func isGzip(_ url: URL) -> Bool {
        KrakenReadSetPipelineTests.isGzip(url)
    }

    static func plainText(of url: URL) throws -> String {
        try KrakenReadSetPipelineTests.plainText(of: url)
    }
}
