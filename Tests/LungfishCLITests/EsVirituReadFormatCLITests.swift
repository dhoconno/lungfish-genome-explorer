// EsVirituReadFormatCLITests.swift - `esviritu detect --read-format` parsing and auto-detection (NEW-06)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
import LungfishIO
@testable import LungfishWorkflow

final class EsVirituReadFormatCLITests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeFASTQ(_ headers: [String], name: String = "reads.fastq") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-esviritu-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let url = dir.appendingPathComponent(name)
        try headers.map { "@\($0)\nACGT\n+\nIIII\n" }.joined()
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func config(_ arguments: [String]) throws -> EsVirituConfig {
        let command = try EsVirituCommand.DetectSubcommand.parse(["detect"] + arguments)
        return try command.makeConfigForTesting(
            databaseURL: URL(fileURLWithPath: "/db/esviritu"),
            outputDirectory: URL(fileURLWithPath: "/tmp/esviritu")
        )
    }

    private func pValue(_ config: EsVirituConfig) -> String? {
        let args = config.esVirituArguments()
        guard let index = args.firstIndex(of: "-p") else { return nil }
        return args[index + 1]
    }

    func testAutoDetectsStrictlyInterleavedFile() throws {
        let url = try makeFASTQ(["a 1:N:0:1", "a 2:N:0:1", "b 1:N:0:1", "b 2:N:0:1"])
        let cfg = try config(["--input", url.path, "--sample", "s"])
        XCTAssertEqual(cfg.readFormat, .interleaved)
        XCTAssertEqual(pValue(cfg), "interleaved")
        XCTAssertEqual(cfg.inputLayout?.layout, .strictlyInterleaved)
    }

    func testAutoRunsMixedFileUnpaired() throws {
        let url = try makeFASTQ(["a/1", "a/2", "merged", "b/1", "b/2"])
        let cfg = try config(["--input", url.path, "--sample", "s"])
        XCTAssertEqual(pValue(cfg), "unpaired")
        XCTAssertEqual(cfg.inputLayout?.layout, .mixedInterleaved)
        XCTAssertEqual(cfg.inputLayout?.matePairs, 2)
        XCTAssertEqual(cfg.inputLayout?.unpairedRecords, 1)
    }

    func testAutoRunsSingleEndFileUnpaired() throws {
        let url = try makeFASTQ(["a", "b", "c"])
        let cfg = try config(["--input", url.path, "--sample", "s"])
        XCTAssertEqual(pValue(cfg), "unpaired")
        XCTAssertEqual(cfg.inputLayout?.layout, .singleEnd)
    }

    func testExplicitReadFormatParses() throws {
        let url = try makeFASTQ(["a", "b"])
        XCTAssertEqual(try config(["--input", url.path, "--sample", "s", "--read-format", "interleaved"]).readFormat, .interleaved)
        XCTAssertEqual(try config(["--input", url.path, "--sample", "s", "--read-format", "unpaired"]).readFormat, .unpaired)
    }

    func testPairedFlagStillWorks() throws {
        let r1 = try makeFASTQ(["a"], name: "s_R1.fastq")
        let r2 = try makeFASTQ(["a"], name: "s_R2.fastq")
        let cfg = try config(["--input", r1.path, r2.path, "--sample", "s", "--paired"])
        XCTAssertEqual(pValue(cfg), "paired")
        XCTAssertNil(cfg.inputLayout)
    }

    func testPairedConflictsWithInterleaved() throws {
        let url = try makeFASTQ(["a"])
        XCTAssertThrowsError(try config(["--input", url.path, "--sample", "s", "--paired", "--read-format", "interleaved"]))
    }

    func testInvalidReadFormatIsRejected() {
        XCTAssertThrowsError(try EsVirituCommand.DetectSubcommand.parse([
            "detect", "--input", "/x.fastq", "--sample", "s", "--read-format", "mixed",
        ]))
    }
}
