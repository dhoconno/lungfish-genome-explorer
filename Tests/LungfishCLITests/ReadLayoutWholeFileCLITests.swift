// ReadLayoutWholeFileCLITests.swift - import fastq and fastq deinterleave on files of real record counts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// Row READ-LAYOUT-PARTIAL-SCAN, the CLI tests of ruling section 6. No test here needs a managed tool, since
/// `--no-optimize-storage` stores the file as given and a mixed file is split in process.
final class ReadLayoutWholeFileCLITests: XCTestCase {

    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "read-layout-cli")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func importFile(_ url: URL, pairing: String) async throws -> URL {
        let command = try ImportCommand.FastqSubcommand.parse([
            url.path, "--project", project.path, "--platform", "illumina", "--quality-binning", "none",
            "--no-optimize-storage", "--no-color", "--pairing", pairing,
        ])
        try await command.run()
        let stem = url.deletingPathExtension().lastPathComponent
        return project.appendingPathComponent("Imports/\(stem).lungfishfastq", isDirectory: true)
    }

    private func sidecar(of bundle: URL) throws -> (metadata: PersistedFASTQMetadata, raw: [String: Any], fastq: URL) {
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        let data = try Data(contentsOf: FASTQMetadataStore.metadataURL(for: fastq))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (metadata, raw, fastq)
    }

    private func count(_ classification: ReadClassification?, _ role: ReadClassification.FileRole) -> Int? {
        classification?.files.first { $0.role == role }?.readCount
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - import fastq

    /// Red at ebe9373cf, whose sidecar recorded `interleaved` and no counts. At the lane's head the label is right,
    /// so its count assertions are the red part.
    func testImportAutoRecordsMixedWithCounts() async throws {
        let input = root.appendingPathComponent("mix.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(60_000), .singles(20_000)], to: input)

        let stored = try sidecar(of: try await importFile(input, pairing: "auto"))

        XCTAssertEqual(stored.metadata.ingestion?.pairingMode, .singleEnd)
        XCTAssertEqual(stored.metadata.ingestion?.pairingSource, .detected)
        XCTAssertEqual(count(stored.metadata.readClassification, .pairedR1), 60_000)
        XCTAssertEqual(count(stored.metadata.readClassification, .pairedR2), 60_000)
        XCTAssertEqual(count(stored.metadata.readClassification, .unpaired), 20_000)
        let recorded = try XCTUnwrap(stored.raw["recordedReadCount"] as? [String: Any], "the count and its size are recorded")
        XCTAssertEqual(recorded["paired_r1"] as? Int, 60_000)
        XCTAssertEqual(recorded["paired_r2"] as? Int, 60_000)
        XCTAssertEqual(recorded["unpaired"] as? Int, 20_000)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: stored.fastq.path)[.size] as? Int)
        XCTAssertEqual(recorded["storedSizeBytes"] as? Int, size)
    }

    /// A file of one kind records a count and no roles, so nothing that reads the roles moves.
    func testImportOfOneKindRecordsACountAndNoRoles() async throws {
        let pairs = root.appendingPathComponent("pairs.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(70)], to: pairs)
        let storedPairs = try sidecar(of: try await importFile(pairs, pairing: "auto"))
        XCTAssertEqual(storedPairs.metadata.ingestion?.pairingMode, .interleaved)
        XCTAssertNil(storedPairs.metadata.readClassification)
        XCTAssertEqual((storedPairs.raw["recordedReadCount"] as? [String: Any])?["paired_r1"] as? Int, 70)

        let singles = root.appendingPathComponent("singles.fastq")
        try FASTQLayoutRecordFixtures.write([.singles(70)], to: singles)
        let bundle = try await importFile(singles, pairing: "auto")
        let storedSingles = try sidecar(of: bundle)
        XCTAssertEqual(storedSingles.metadata.ingestion?.pairingMode, .singleEnd)
        XCTAssertNil(storedSingles.metadata.readClassification)
        XCTAssertEqual((storedSingles.raw["recordedReadCount"] as? [String: Any])?["unpaired"] as? Int, 70)
        XCTAssertEqual(FASTQInputLayoutResolver.resolve(inputURLs: [bundle]).layout, .singleEnd)
    }

    /// The workaround the 2026.10.29 page gives. A person's Single-end binds on a mixed file past the old window, and
    /// no recorded count overrules it.
    func testPairingSingleStaysTheWorkaround() async throws {
        let input = root.appendingPathComponent("mix.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(60_000), .singles(20_000)], to: input)

        let bundle = try await importFile(input, pairing: "single")

        let stored = try sidecar(of: bundle)
        XCTAssertEqual(stored.metadata.ingestion?.pairingMode, .singleEnd)
        XCTAssertEqual(stored.metadata.ingestion?.pairingSource, .explicit)
        XCTAssertNil(stored.metadata.readClassification)
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [bundle])
        XCTAssertEqual(resolution.layout, .singleEnd, resolution.reason)
        XCTAssertEqual(resolution.source, .bundleMetadata)
        XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: bundle).layout, .singleEnd)
    }

    // MARK: - fastq deinterleave

    /// Red at ebe9373cf, where it exited 0 with 10,000 false pairs. Items 5 and 6 turned it green, before this test.
    func testFastqDeinterleaveRefusesMixedWithoutUnpaired() async throws {
        let input = root.appendingPathComponent("mix.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(60_000), .singles(20_000)], to: input)
        let out1 = root.appendingPathComponent("r1.fastq"), out2 = root.appendingPathComponent("r2.fastq")
        do {
            try await FastqDeinterleaveSubcommand.parse([input.path, "--out1", out1.path, "--out2", out2.path]).run()
            XCTFail("a mixed file must not be split by position")
        } catch let error as ValidationError {
            XCTAssertEqual(FastqDeinterleaveSubcommand.exitCode(for: error), .validationFailure, "exit 64")
            XCTAssertTrue(error.message.contains("All 140000 records"), error.message)
            XCTAssertTrue(error.message.contains("60000 adjacent mate pairs"), error.message)
            XCTAssertTrue(error.message.contains("20000 unpaired reads"), error.message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out2.path))
    }

    /// Red at ebe9373cf, which dropped the odd read with exit 0. Items 5 and 6 turned it green, before this test.
    func testFastqDeinterleaveSplitsMixedByName() async throws {
        let input = root.appendingPathComponent("mix.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(60_000), .singles(20_001)], to: input)
        let out1 = root.appendingPathComponent("r1.fastq"), out2 = root.appendingPathComponent("r2.fastq")
        let unpaired = root.appendingPathComponent("single.fastq")

        try await FastqDeinterleaveSubcommand.parse([
            input.path, "--out1", out1.path, "--out2", out2.path, "--unpaired", unpaired.path,
        ]).run()

        let records = try [out1, out2, unpaired].map { try FASTQPairInterleaver.countRecords(in: $0) }
        XCTAssertEqual(records, [60_000, 60_000, 20_001])
        XCTAssertEqual(records.reduce(0, +), 140_001)
    }

    /// Item 12. `readLayout`, its reason, `pairs` and `unpairedReads` were recorded by the by-name route already.
    /// `scannedRecords` and `scannedWholeFile` are the red part. A second run of the recorded arguments writes the
    /// same bytes.
    func testDeinterleaveRecordNamesWholeFileLayoutAndReplays() async throws {
        let input = root.appendingPathComponent("mix.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(60_000), .singles(20_000)], to: input)
        let first = root.appendingPathComponent("first", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let outputs = ["r1.fastq", "r2.fastq", "single.fastq"].map { first.appendingPathComponent($0) }

        try await FastqDeinterleaveSubcommand.parse([
            input.path, "--out1", outputs[0].path, "--out2", outputs[1].path, "--unpaired", outputs[2].path,
        ]).run()

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: first))
        let parameters = try XCTUnwrap(envelope.legacyRun?.parameters)
        guard case .string(let layout)? = parameters["readLayout"],
              case .string(let reason)? = parameters["readLayoutReason"],
              case .integer(let pairs)? = parameters["pairs"],
              case .integer(let single)? = parameters["unpairedReads"] else {
            return XCTFail("\(parameters)")
        }
        XCTAssertEqual(layout, FASTQInputLayout.mixedMergedAndPairs.rawValue)
        XCTAssertTrue(reason.contains("All 140000 records"), reason)
        XCTAssertEqual(pairs, 60_000)
        XCTAssertEqual(single, 20_000)
        XCTAssertEqual(parameters["scannedRecords"], .integer(140_000))
        XCTAssertEqual(parameters["scannedWholeFile"], .boolean(true))
        XCTAssertTrue(envelope.reproducibleCommand.contains("--unpaired"), envelope.reproducibleCommand)

        let again = root.appendingPathComponent("again", isDirectory: true)
        try FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
        let replayed = ["r1.fastq", "r2.fastq", "single.fastq"].map { again.appendingPathComponent($0) }
        try await FastqDeinterleaveSubcommand.parse([
            input.path, "--out1", replayed[0].path, "--out2", replayed[1].path, "--unpaired", replayed[2].path,
        ]).run()
        for (one, other) in zip(outputs, replayed) {
            XCTAssertEqual(try digest(one), try digest(other), one.lastPathComponent)
        }
    }
}
