// FASTQBatchImporterUnpairedReadsTests.swift - A run's reads without a mate import beside its pairs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// ENA's mirror and the SRA Toolkit write some runs as three files, mates 1
/// and 2 in `<run>_1` and `<run>_2` and the spots whose mate is missing in
/// `<run>`. `import fastq` took the third file for a second sample of the
/// same name, found the pair's bundle and skipped it, so the bundle held
/// part of the run (finding F7-S1). The window imports through the same
/// command, so it lost those reads too.
final class FASTQBatchImporterUnpairedReadsTests: XCTestCase {

    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-unpaired")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Detection

    func testDetectionJoinsARunsUnpairedFileToItsMatesOnly() {
        let samples = FASTQBatchImporter.detectPairs(from: Self.files([
            "SRR1_1.fastq.gz", "SRR1_2.fastq.gz", "SRR1.fastq.gz", "S_R1.fastq", "S_R2.fastq", "S.fastq", "lone.fastq",
        ]))

        XCTAssertEqual(samples.map(\.sampleName).sorted(), ["S", "S", "SRR1", "lone"])
        let run = samples.first { $0.sampleName == "SRR1" }
        XCTAssertEqual(run?.inputFiles.map(\.lastPathComponent), ["SRR1_1.fastq.gz", "SRR1_2.fastq.gz", "SRR1.fastq.gz"])
        XCTAssertEqual(run?.unpaired?.lastPathComponent, "SRR1.fastq.gz")
        XCTAssertTrue(
            samples.filter { $0.sampleName == "S" }.allSatisfy { $0.unpaired == nil },
            "a bare file beside an _R1 and _R2 pair keeps its own sample"
        )
    }

    func testSingleAndInterleavedPairingStillImportEachFileOnItsOwn() {
        let detected = FASTQBatchImporter.detectPairs(from: Self.files(["SRR1_1.fastq", "SRR1_2.fastq", "SRR1.fastq"]))
        for pairing in [FASTQBatchImporter.ImportPairing.single, .interleaved] {
            let samples = FASTQBatchImporter.applyPairing(pairing, to: detected)
            XCTAssertEqual(samples.map(\.sampleName), ["SRR1", "SRR1_1", "SRR1_2"], "\(pairing)")
            XCTAssertTrue(samples.allSatisfy { $0.r2 == nil && $0.unpaired == nil }, "\(pairing)")
        }
    }

    // MARK: - A three-file run

    func testAThreeFileRunImportsEveryReadWithItsRole() async throws {
        let files = try writeRun("SRR9000003", pairedSpots: [1, 2, 3, 4, 6], unpairedSpots: [5, 7])

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: FASTQBatchImporter.detectPairs(from: files),
            config: config()
        )

        XCTAssertEqual(result.completed, 1, "Errors: \(result.errors)")
        XCTAssertEqual(result.skipped, 0, "no file of the run is left out")
        let bundle = project.appendingPathComponent("Imports/SRR9000003.lungfishfastq", isDirectory: true)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        XCTAssertEqual(
            try Self.headers(of: fastq),
            ["1", "1", "2", "2", "3", "3", "4", "4", "6", "6", "5", "7"].map { "SRR9000003.\($0) \($0) length=8" },
            "each R1 record is followed by its R2 record, then come the reads without a mate"
        )

        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        XCTAssertEqual(metadata.readClassification, ReadClassification(files: [
            .init(filename: "SRR9000003.fastq.gz", role: .pairedR1, readCount: 5),
            .init(filename: "SRR9000003.fastq.gz", role: .pairedR2, readCount: 5),
            .init(filename: "SRR9000003.fastq.gz", role: .unpaired, readCount: 2),
        ]))
        // A count with single reads is labelled single-end, the convention
        // every importer follows. Every tool still plans the file from its
        // counts, below.
        XCTAssertEqual(metadata.ingestion?.pairingMode, .singleEnd)
        XCTAssertEqual(
            metadata.ingestion?.originalFilenames,
            ["SRR9000003_1.fastq", "SRR9000003_2.fastq", "SRR9000003.fastq"]
        )

        // Every tool reads the bundle as five pairs and two orphans.
        let plan = try await ReadSetResolver(
            materializationDirectory: root.appendingPathComponent("plan", isDirectory: true)
        ).plan(for: bundle, capability: .bothInOneRunAsSeparateFiles)
        XCTAssertEqual(plan.composition.pairedFragments, 5)
        XCTAssertEqual(plan.composition.orphanReads, 2)

        // The record names the three files and the reads each one held.
        let envelope = try Self.envelope(in: bundle)
        let runFiles = ["SRR9000003_1.fastq", "SRR9000003_2.fastq", "SRR9000003.fastq"]
        let inputNames = envelope.files.filter { $0.role == .input }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        XCTAssertEqual(Array(inputNames.prefix(3)), runFiles, "the run's inputs come first, before each step's")
        let importStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "lungfish import fastq" })
        XCTAssertEqual(importStep.inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, runFiles)
        XCTAssertEqual(Array(envelope.argv.prefix(6)), ["lungfish-cli", "import", "fastq"] + files.map(\.path))
        XCTAssertEqual(envelope.options.resolvedDefaults["inputReadCounts"], .dictionary([
            "SRR9000003_1.fastq": .integer(5),
            "SRR9000003_2.fastq": .integer(5),
            "SRR9000003.fastq": .integer(2),
        ]))
        let interleave = try XCTUnwrap(envelope.steps.first { $0.toolName == "Lungfish Read-Set Interleave" })
        XCTAssertEqual(
            interleave.inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent },
            runFiles
        )
        XCTAssertEqual(interleave.resolvedOptions["pairs"], .integer(5))
        XCTAssertEqual(interleave.resolvedOptions["singleReads"], .integer(2))
        XCTAssertEqual(envelope.options.explicit["unpaired"], .file(files[2]))
    }

    func testARecipeRefusesARunWithReadsWithoutAMateAndNamesTheFile() async throws {
        let files = try writeRun("SRR9000004", pairedSpots: [1, 2], unpairedSpots: [3])

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: FASTQBatchImporter.detectPairs(from: files),
            config: FASTQBatchImporter.ImportConfig(
                projectDirectory: project,
                platform: .given(.illumina),
                recipe: try FASTQBatchImporter.resolveRecipe(named: "vsp2"),
                qualityBinning: QualityBinningScheme.none,
                optimizeStorage: false,
                threads: 1
            )
        )

        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.failed, 1, "a recipe would leave the reads without a mate out")
        XCTAssertTrue(result.errors.first?.error.contains("SRR9000004.fastq holds reads whose mate is missing") == true, "\(result.errors)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("Imports/SRR9000004.lungfishfastq").path
        ))
    }

    // MARK: - A two-file run

    func testATwoFileRunImportsAsBefore() async throws {
        let files = try writeRun("SRR9000002", pairedSpots: [1, 2, 3], unpairedSpots: [])

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: FASTQBatchImporter.detectPairs(from: files),
            config: config()
        )

        XCTAssertEqual(result.completed, 1, "Errors: \(result.errors)")
        let bundle = project.appendingPathComponent("Imports/SRR9000002.lungfishfastq", isDirectory: true)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        XCTAssertEqual(
            try Self.headers(of: fastq),
            ["1", "1", "2", "2", "3", "3"].map { "SRR9000002.\($0) \($0) length=8" }
        )
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        XCTAssertNil(metadata.readClassification, "a run of pairs only records no classification")
        XCTAssertEqual(metadata.ingestion?.pairingMode, .interleaved)
        XCTAssertEqual(metadata.ingestion?.pairingSource, .detected)
        XCTAssertEqual(metadata.ingestion?.originalFilenames, ["SRR9000002_1.fastq", "SRR9000002_2.fastq"])

        let envelope = try Self.envelope(in: bundle)
        XCTAssertNil(envelope.options.explicit["unpaired"])
        XCTAssertNil(envelope.options.resolvedDefaults["inputReadCounts"])
        XCTAssertFalse(envelope.steps.contains { $0.toolName == "Lungfish Read-Set Interleave" })
        XCTAssertEqual(Array(envelope.argv.prefix(6)), ["lungfish-cli", "import", "fastq"] + files.map(\.path) + ["--project"])
    }

    // MARK: - Helpers

    private static func files(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/reads").appendingPathComponent($0) }
    }

    private func config() -> FASTQBatchImporter.ImportConfig {
        FASTQBatchImporter.ImportConfig(
            projectDirectory: project,
            platform: .given(.illumina),
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: false,
            threads: 1
        )
    }

    /// Writes one run as fasterq-dump names it, `<run>_1.fastq` and
    /// `<run>_2.fastq` for the spots with both reads, and `<run>.fastq` for
    /// the spots whose mate is missing when there are any.
    private func writeRun(_ run: String, pairedSpots: [Int], unpairedSpots: [Int]) throws -> [URL] {
        let folder = root.appendingPathComponent("download-\(run)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ spots: [Int], bases: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            let text = spots.map { "@\(run).\($0) \($0) length=8\n\(bases)\n+\nIIIIIIII\n" }.joined()
            try Data(text.utf8).write(to: url)
            return url
        }
        var files = [
            try write("\(run)_1.fastq", pairedSpots, bases: "ACGTACGT"),
            try write("\(run)_2.fastq", pairedSpots, bases: "TTGGCCAA"),
        ]
        if !unpairedSpots.isEmpty {
            files.append(try write("\(run).fastq", unpairedSpots, bases: "GATTACAG"))
        }
        return files
    }

    /// Every record header of a plain or gzip FASTQ, in file order.
    private static func headers(of fastq: URL) throws -> [String] {
        try FASTQReadLayoutClassifier.readHeaders(from: fastq, limit: 1_000).headers
    }

    private static func envelope(in bundle: URL) throws -> ProvenanceEnvelope {
        let url = bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let data = PortablePath.resolveJSON(try Data(contentsOf: url), forFileAt: url)
        return try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
    }
}
