// EsVirituReadFormatTests.swift - EsViritu -p read format and interleaved guard (NEW-06, D19)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO

final class EsVirituReadFormatTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeFASTQ(_ headers: [String], name: String = "reads.fastq") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-esviritu-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let url = dir.appendingPathComponent(name)
        try headers.map { "@\($0)\nACGT\n+\nIIII\n" }.joined()
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func config(
        files: [URL],
        isPairedEnd: Bool = false,
        readFormat: EsVirituReadFormat? = nil
    ) -> EsVirituConfig {
        EsVirituConfig(
            inputFiles: files,
            isPairedEnd: isPairedEnd,
            sampleName: "s",
            outputDirectory: URL(fileURLWithPath: "/tmp/esviritu-out"),
            databasePath: URL(fileURLWithPath: "/tmp/esviritu-db"),
            readFormat: readFormat
        )
    }

    private func pValue(_ config: EsVirituConfig) -> String? {
        let args = config.esVirituArguments()
        guard let index = args.firstIndex(of: "-p"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    // MARK: - Arguments

    func testInterleavedFormatPassesInterleavedReadFormat() {
        let cfg = config(files: [URL(fileURLWithPath: "/x/reads.fastq")], readFormat: .interleaved)
        XCTAssertEqual(pValue(cfg), "interleaved")
        XCTAssertFalse(cfg.isPairedEnd)
    }

    func testMixedInputRunsUnpaired() {
        let cfg = config(files: [URL(fileURLWithPath: "/x/reads.fastq")], readFormat: .unpaired)
        XCTAssertEqual(pValue(cfg), "unpaired")
    }

    func testLegacyIsPairedEndStillDrivesFormat() {
        XCTAssertEqual(pValue(config(files: [URL(fileURLWithPath: "/a")])), "unpaired")
        let paired = config(files: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")], isPairedEnd: true)
        XCTAssertEqual(paired.readFormat, .paired)
        XCTAssertEqual(pValue(paired), "paired")
    }

    func testExplicitPairedFormatSetsIsPairedEnd() {
        let cfg = config(files: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")], readFormat: .paired)
        XCTAssertTrue(cfg.isPairedEnd)
    }

    func testFormatForSingleFileLayouts() {
        XCTAssertEqual(EsVirituReadFormat.forSingleFile(.strictlyInterleaved), .interleaved)
        XCTAssertEqual(EsVirituReadFormat.forSingleFile(.mixedInterleaved), .unpaired)
        XCTAssertEqual(EsVirituReadFormat.forSingleFile(.singleEnd), .unpaired)
    }

    func testInputLabels() {
        XCTAssertEqual(EsVirituReadFormat.inputLabel(format: .interleaved, layout: .strictlyInterleaved), "Interleaved paired-end reads")
        XCTAssertEqual(EsVirituReadFormat.inputLabel(format: .unpaired, layout: .mixedInterleaved), "Mixed paired and merged reads (run as single-end)")
        XCTAssertEqual(EsVirituReadFormat.inputLabel(format: .unpaired, layout: .singleEnd), "Single-end reads")
        XCTAssertEqual(EsVirituReadFormat.inputLabel(format: .paired, layout: nil), "Paired-end reads")
    }

    // MARK: - Validation and Codable

    func testInterleavedRequiresOneFile() throws {
        let a = try makeFASTQ(["a/1", "a/2"], name: "a.fastq")
        let b = try makeFASTQ(["b/1", "b/2"], name: "b.fastq")
        let dbDir = a.deletingLastPathComponent()
        let cfg = EsVirituConfig(
            inputFiles: [a, b],
            isPairedEnd: false,
            sampleName: "s",
            outputDirectory: dbDir,
            databasePath: dbDir,
            readFormat: .interleaved
        )
        XCTAssertThrowsError(try cfg.validate()) { error in
            guard case EsVirituConfigError.interleavedRequiresOneFile(let got) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(got, 2)
        }
    }

    func testCodableRoundTripKeepsFormatAndLayout() throws {
        let layout = FASTQReadLayoutClassifier.classify(headers: ["a/1", "a/2", "m"], scannedWholeFile: true)
        var cfg = config(files: [URL(fileURLWithPath: "/x/reads.fastq")], readFormat: .unpaired)
        cfg.inputLayout = layout
        let decoded = try JSONDecoder().decode(EsVirituConfig.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(decoded, cfg)
        XCTAssertEqual(decoded.inputLayout?.layout, .mixedInterleaved)
    }

    func testLegacyJSONWithoutReadFormatDecodesFromIsPairedEnd() throws {
        let json = """
        {"inputFiles":["file:///a","file:///b"],"isPairedEnd":true,"sampleName":"s",
         "outputDirectory":"file:///o","databasePath":"file:///d"}
        """
        let decoded = try JSONDecoder().decode(EsVirituConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.readFormat, .paired)
    }

    func testSummaryParametersRecordReadFormatAndLayout() {
        var cfg = config(files: [URL(fileURLWithPath: "/x")], readFormat: .unpaired)
        cfg.inputLayout = FASTQReadLayoutClassifier.classify(headers: ["a/1", "a/2", "m"], scannedWholeFile: true)
        let params = cfg.summaryParameters()
        XCTAssertEqual(params["readFormat"], .string("unpaired"))
        XCTAssertEqual(params["inputReadLayout"], .string("mixed_interleaved"))
        XCTAssertEqual(params["inputReadLayoutMatePairs"], .int(1))
        XCTAssertEqual(params["inputReadLayoutUnpairedRecords"], .int(1))
    }

    // MARK: - Runtime interleaved guard

    func testGuardKeepsStrictlyInterleavedInput() throws {
        let url = try makeFASTQ(["a 1:N:0:1", "a 2:N:0:1", "b 1:N:0:1", "b 2:N:0:1"])
        let verified = config(files: [url], readFormat: .interleaved).verifyingInterleavedInput()
        XCTAssertEqual(verified.readFormat, .interleaved)
        XCTAssertEqual(verified.inputLayout?.layout, .strictlyInterleaved)
    }

    func testGuardDowngradesMixedInputToUnpaired() throws {
        let url = try makeFASTQ(["a/1", "a/2", "merged_read", "b/1", "b/2"])
        let verified = config(files: [url], readFormat: .interleaved).verifyingInterleavedInput()
        XCTAssertEqual(verified.readFormat, .unpaired)
        XCTAssertEqual(pValue(verified), "unpaired")
        XCTAssertEqual(verified.inputLayout?.layout, .mixedInterleaved)
        XCTAssertEqual(verified.inputLayout?.unpairedRecords, 1)
    }

    func testGuardDowngradesMultiFileInterleavedToUnpaired() {
        let verified = config(
            files: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")],
            readFormat: .interleaved
        ).verifyingInterleavedInput()
        XCTAssertEqual(verified.readFormat, .unpaired)
    }

    func testGuardLeavesOtherFormatsAlone() {
        let cfg = config(files: [URL(fileURLWithPath: "/does-not-exist")], readFormat: .unpaired)
        XCTAssertEqual(cfg.verifyingInterleavedInput(), cfg)
    }
}
