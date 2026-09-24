// ClassificationReadFormatTests.swift - Interleaved input handling for Kraken2 classification
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// A `.lungfishfastq` bundle whose pairing is interleaved used to reach
/// kraken2 as one single-end file: `--paired` was added only for two input
/// files. `ClassificationConfig` now carries an explicit read format, the
/// pipeline splits an interleaved input into two mate files for
/// `kraken2 --paired`, and the recorded CLI command pins the choice.
final class ClassificationReadFormatTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassificationReadFormatTests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeConfig(
        inputFiles: [URL],
        isPairedEnd: Bool = false,
        interleavedInput: Bool = false
    ) -> ClassificationConfig {
        ClassificationConfig(
            inputFiles: inputFiles,
            isPairedEnd: isPairedEnd,
            interleavedInput: interleavedInput,
            databaseName: "Viral",
            databasePath: URL(fileURLWithPath: "/opt/lungfish/db/Viral"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out")
        )
    }

    private let single = [URL(fileURLWithPath: "/data/sample.lungfishfastq/sample.fastq.gz")]
    private let pair = [URL(fileURLWithPath: "/data/s_R1.fastq.gz"), URL(fileURLWithPath: "/data/s_R2.fastq.gz")]

    // MARK: - Read format model

    func testReadFormatDerivesFromPairingFlags() {
        XCTAssertEqual(makeConfig(inputFiles: single).readFormat, .unpaired)
        XCTAssertEqual(makeConfig(inputFiles: single, interleavedInput: true).readFormat, .interleaved)
        XCTAssertEqual(makeConfig(inputFiles: pair, isPairedEnd: true).readFormat, .paired)
    }

    func testForSingleFileMirrorsEsViritu() {
        XCTAssertEqual(ClassificationConfig.ReadFormat.forSingleFile(.strictlyInterleaved), .interleaved)
        XCTAssertEqual(ClassificationConfig.ReadFormat.forSingleFile(.mixedInterleaved), .unpaired)
        XCTAssertEqual(ClassificationConfig.ReadFormat.forSingleFile(.singleEnd), .unpaired)
        XCTAssertEqual(
            ClassificationConfig.ReadFormat.inputLabel(format: .unpaired, layout: .mixedInterleaved),
            "Mixed paired and merged reads (run as single-end)"
        )
        XCTAssertEqual(
            ClassificationConfig.ReadFormat.inputLabel(format: .interleaved, layout: .strictlyInterleaved),
            "Interleaved paired-end reads"
        )
    }

    func testKraken2ArgumentsAddPairedOnlyForTwoMateFiles() {
        // The interleaved request itself has one file and no kraken2 flag; the
        // pipeline runs the split halves with --paired.
        XCTAssertFalse(makeConfig(inputFiles: single, interleavedInput: true).kraken2Arguments().contains("--paired"))
        XCTAssertTrue(makeConfig(inputFiles: pair, isPairedEnd: true).kraken2Arguments().contains("--paired"))
    }

    func testValidationRejectsInterleavedWithTwoFilesOrPairedFlag() throws {
        let files = try ["a.fastq", "b.fastq"].map { name -> URL in
            let url = root.appendingPathComponent(name)
            try "@r/1\nA\n+\nI\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        XCTAssertThrowsError(try makeConfig(inputFiles: files, interleavedInput: true).validate()) { error in
            guard case ClassificationConfigError.interleavedRequiresOneFile(let got) = error else {
                return XCTFail("Expected interleavedRequiresOneFile, got \(error)")
            }
            XCTAssertEqual(got, 2)
        }
        XCTAssertThrowsError(try makeConfig(inputFiles: files, isPairedEnd: true, interleavedInput: true).validate()) { error in
            guard case ClassificationConfigError.interleavedConflictsWithPairedEnd = error else {
                return XCTFail("Expected interleavedConflictsWithPairedEnd, got \(error)")
            }
        }
    }

    func testCodableRoundTripsAndLegacySidecarsDecodeAsUnpaired() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let layout = FASTQReadLayoutClassification(
            layout: .strictlyInterleaved, scannedRecords: 4, matePairs: 2, unpairedRecords: 0,
            scannedWholeFile: true, metadata: FASTQPairingMetadataHints(), reason: "test"
        )
        var config = makeConfig(inputFiles: single, interleavedInput: true)
        config.inputLayout = layout
        let decoded = try decoder.decode(ClassificationConfig.self, from: try encoder.encode(config))
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.readFormat, .interleaved)
        XCTAssertEqual(decoded.inputLayout, layout)

        // A sidecar written before interleaved support has no key.
        var legacy = try JSONSerialization.jsonObject(with: try encoder.encode(makeConfig(inputFiles: single))) as! [String: Any]
        legacy.removeValue(forKey: "interleavedInput")
        legacy.removeValue(forKey: "inputLayout")
        let legacyDecoded = try decoder.decode(
            ClassificationConfig.self,
            from: try JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertFalse(legacyDecoded.interleavedInput)
        XCTAssertEqual(legacyDecoded.readFormat, .unpaired)
    }

    // MARK: - Recorded CLI command

    func testCLIInvocationPinsTheReadFormat() {
        let interleaved = ClassificationCLIInvocationBuilder.build(for: makeConfig(inputFiles: single, interleavedInput: true)).arguments
        XCTAssertTrue(interleaved.contains("--read-format"), "\(interleaved)")
        XCTAssertEqual(interleaved[interleaved.firstIndex(of: "--read-format")! + 1], "interleaved")
        XCTAssertFalse(interleaved.contains("--paired"))

        let unpaired = ClassificationCLIInvocationBuilder.build(for: makeConfig(inputFiles: single)).arguments
        XCTAssertEqual(unpaired[unpaired.firstIndex(of: "--read-format")! + 1], "unpaired")

        let paired = ClassificationCLIInvocationBuilder.build(for: makeConfig(inputFiles: pair, isPairedEnd: true)).arguments
        XCTAssertTrue(paired.contains("--paired"))
        XCTAssertFalse(paired.contains("--read-format"))
    }

    // MARK: - Split for kraken2

    func testSplitInterleavedInputWritesMateFilesInOrder() async throws {
        let interleaved = root.appendingPathComponent("sample.fastq")
        try """
        @a/1
        AAAA
        +
        IIII
        @a/2
        TTTT
        +
        IIII
        @b/1
        CCCC
        +
        IIII
        @b/2
        GGGG
        +
        IIII

        """.write(to: interleaved, atomically: true, encoding: .utf8)
        let directory = root.appendingPathComponent(ClassificationPipeline.interleavedSplitDirectoryName, isDirectory: true)

        let split = try await ClassificationPipeline.splitInterleavedInput(interleaved, into: directory)

        XCTAssertEqual(split.counts, FASTQPairInterleaver.Counts(r1Records: 2, r2Records: 2, writtenRecords: 4))
        XCTAssertEqual(split.r1.lastPathComponent, "sample_R1.fastq")
        XCTAssertEqual(split.r2.lastPathComponent, "sample_R2.fastq")
        XCTAssertEqual(try String(contentsOf: split.r1, encoding: .utf8), "@a/1\nAAAA\n+\nIIII\n@b/1\nCCCC\n+\nIIII\n")
        XCTAssertEqual(try String(contentsOf: split.r2, encoding: .utf8), "@a/2\nTTTT\n+\nIIII\n@b/2\nGGGG\n+\nIIII\n")
    }

    func testSplitInterleavedInputRejectsAnOddRecordCountAndCleansUp() async throws {
        let interleaved = root.appendingPathComponent("odd.fastq.gz")
        let plain = root.appendingPathComponent("odd.fastq")
        try "@a/1\nAAAA\n+\nIIII\n@a/2\nTTTT\n+\nIIII\n@b/1\nCCCC\n+\nIIII\n".write(to: plain, atomically: true, encoding: .utf8)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-f", plain.path]
        try gzip.run()
        gzip.waitUntilExit()
        let directory = root.appendingPathComponent("split", isDirectory: true)

        do {
            _ = try await ClassificationPipeline.splitInterleavedInput(interleaved, into: directory)
            XCTFail("An odd record count is not a set of pairs")
        } catch FASTQPairInterleaver.InterleaveError.mateCountMismatch {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Failed split must not leave halves behind")
    }
}
