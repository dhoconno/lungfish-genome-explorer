// ReadLayoutWholeFileCLITests.swift - import fastq and fastq deinterleave on files of real record counts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

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

    /// The value of `key` wherever the record keeps it, since the test reads the record by meaning.
    private func recorded(_ key: String, in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] { return String(describing: value) }
            for value in dictionary.values {
                if let found = recorded(key, in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = recorded(key, in: value) { return found }
            }
        }
        return nil
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
        let record = try JSONSerialization.jsonObject(
            with: Data(contentsOf: first.appendingPathComponent(".lungfish-provenance.json")))
        XCTAssertTrue(try XCTUnwrap(recorded("readLayout", in: record)).contains(FASTQInputLayout.mixedMergedAndPairs.rawValue))
        XCTAssertTrue(try XCTUnwrap(recorded("readLayoutReason", in: record)).contains("All 140000 records"))
        XCTAssertTrue(try XCTUnwrap(recorded("pairs", in: record)).contains("60000"))
        XCTAssertTrue(try XCTUnwrap(recorded("unpairedReads", in: record)).contains("20000"))
        XCTAssertTrue(try XCTUnwrap(recorded("scannedRecords", in: record)).contains("140000"))
        let wholeFile = try XCTUnwrap(recorded("scannedWholeFile", in: record))
        XCTAssertTrue(wholeFile.contains("1") || wholeFile.contains("true"), wholeFile)
        XCTAssertTrue(envelope.reproducibleCommand.contains("--unpaired"), envelope.reproducibleCommand)

        // The replay runs the recorded command with its outputs moved, so a record that dropped `--unpaired`, a path or
        // its quoting fails here (QA blocker, BIO review should-fix 2).
        let words = try XCTUnwrap(ProvenanceCommandPresentation.split(envelope.reproducibleCommand), envelope.reproducibleCommand)
            .compactMap { piece -> String? in
                if case .word(let word) = piece { return word.value }
                return nil
            }
        let verb = try XCTUnwrap(words.firstIndex(of: "deinterleave"), envelope.reproducibleCommand)
        var tokens = Array(words[(verb + 1)...])
        XCTAssertEqual(tokens.first, input.path)
        XCTAssertTrue(tokens.contains("--unpaired"), envelope.reproducibleCommand)
        let again = root.appendingPathComponent("again", isDirectory: true)
        try FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
        let replayed = ["r1.fastq", "r2.fastq", "single.fastq"].map { again.appendingPathComponent($0) }
        for (flag, output) in zip(["--out1", "--out2", "--unpaired"], replayed) {
            let at = try XCTUnwrap(tokens.firstIndex(of: flag), "\(flag) is in the recorded command")
            tokens[at + 1] = output.path
        }
        try await FastqDeinterleaveSubcommand.parse(tokens).run()
        let recordedOutputs = envelope.outputs + envelope.steps.flatMap(\.outputs)
        for (one, other) in zip(outputs, replayed) {
            XCTAssertEqual(try digest(one), try digest(other), one.lastPathComponent)
            let entry = recordedOutputs.first { URL(fileURLWithPath: $0.path).lastPathComponent == one.lastPathComponent }
            XCTAssertEqual(entry?.checksumSHA256, try digest(other), "the record holds the digest of \(one.lastPathComponent)")
        }
    }

    // MARK: - An R1/R2 import records its count (BIO review, ruling 2)

    /// Writes `<stem>_1.fastq` and `<stem>_2.fastq`, `pairs` reads each, mates named by `names`, and imports them.
    private func importMates(stem: String, pairs: Int, names: (Int) -> (String, String)) async throws -> URL {
        let folder = root.appendingPathComponent("\(stem)-run", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var first = "", second = ""
        for index in 0..<pairs {
            let mates = names(index)
            first += "@\(mates.0)\nACGTACGT\n+\nIIIIIIII\n"
            second += "@\(mates.1)\nTTGGCCAA\n+\nIIIIIIII\n"
        }
        try first.write(to: folder.appendingPathComponent("\(stem)_1.fastq"), atomically: true, encoding: .utf8)
        try second.write(to: folder.appendingPathComponent("\(stem)_2.fastq"), atomically: true, encoding: .utf8)
        try await ImportCommand.FastqSubcommand.parse([
            folder.path, "--project", project.path, "--platform", "illumina", "--quality-binning", "none",
            "--no-optimize-storage", "--no-color",
        ]).run()
        return project.appendingPathComponent("Imports/\(stem).lungfishfastq", isDirectory: true)
    }

    /// Red at the lane's head, where an R1/R2 import recorded no count and a wizard said the layout was decided when
    /// the run starts. The pairs are 3,000 records, past the 2,000 a wizard reads on its own.
    func testImportOfAPairRecordsItsCountAndAWizardNamesTheLayout() async throws {
        let bundle = try await importMates(stem: "SRR200", pairs: 1_500) { ("p\($0)/1", "p\($0)/2") }

        let stored = try sidecar(of: bundle)
        let counted = try XCTUnwrap(stored.metadata.recordedReadCount, "the count is recorded")
        XCTAssertEqual([counted.pairedR1, counted.pairedR2, counted.unpaired], [1_500, 1_500, 0])
        XCTAssertNil(stored.metadata.readClassification, "a file of one kind records no roles")
        let sample = MetagenomicsSampleInput(sampleId: "pair", fastq1: bundle, fastq2: nil)
        let decidedAtRunTime = "Read layout is decided when the run starts"
        let esViritu = await EsVirituSampleReadPlan.planned(for: sample)
        XCTAssertEqual(esViritu.layout?.layout, .strictlyInterleaved)
        XCTAssertNotEqual(esViritu.label, decidedAtRunTime)
        let kraken = await ClassificationSampleReadPlan.planned(for: sample)
        XCTAssertEqual(kraken.layout?.layout, .strictlyInterleaved)
        XCTAssertNotEqual(kraken.label, decidedAtRunTime)
    }

    /// Row READ-LAYOUT-DOTTED-MATES moved this pin of BIO ruling 2. The scan reads a stored pair named `SRR123.1.1` and
    /// `SRR123.1.2` as mates, so its count is true and is kept like any other.
    func testImportOfAPairWithDottedMateNamesRecordsItsCount() async throws {
        let bundle = try await importMates(stem: "SRR201", pairs: 3) { ("SRR201.\($0 + 1).1", "SRR201.\($0 + 1).2") }

        let stored = try sidecar(of: bundle)
        XCTAssertEqual(stored.metadata.recordedReadCount?.pairedR1, 3)
        XCTAssertEqual(stored.metadata.recordedReadCount?.pairedR2, 3)
        XCTAssertEqual(stored.metadata.recordedReadCount?.unpaired, 0)
        XCTAssertNil(stored.metadata.readClassification)
    }

    /// The control of BIO review B1. A recorded pair that holds no mates at all keeps the split by name, so every read
    /// goes to the unpaired file, and the name check does not turn it into a pair.
    func testFastqDeinterleaveKeepsANameSplitWhenARecordedPairHoldsNoMates() async throws {
        let input = root.appendingPathComponent("lone.fastq")
        try FASTQLayoutRecordFixtures.write([.singles(6)], to: input)
        let bundle = try await importFile(input, pairing: "interleaved")
        let paths = ["r1.fastq", "r2.fastq", "single.fastq"].map { root.appendingPathComponent($0) }

        try await FastqDeinterleaveSubcommand.parse([
            bundle.path, "--out1", paths[0].path, "--out2", paths[1].path, "--unpaired", paths[2].path,
        ]).run()

        XCTAssertEqual(try paths.map { try FASTQPairInterleaver.countRecords(in: $0) }, [0, 0, 6])
    }
}
