// FASTATextModePinTests.swift - The FASTA that convert, translate and extract sequence write in text mode
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A55 (2.6 row 213), milestone M1. BIO's condition on panel decision C6 is that the FASTA
// these three leaves write in text mode, to a file or to standard output, stays byte for byte when the
// lane moves their text off standard output under `--format json`. These cases pin those bytes at the
// base, together with the text lines each leaf prints around them, so the move cannot change either.
// They pass before any Sources edit.
//
// Each case runs the command in this process and reads standard output and standard error from files
// that stand in for them (`StandardStreamCapture`). A file never fills a pipe, so a long run cannot block.

import Darwin
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishTestSupport

/// Runs an operation with standard output and standard error pointed at files, then puts both back.
enum StandardStreamCapture {
    struct Streams {
        let standardOutput: Data
        let standardError: Data
        var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }
        var standardErrorText: String { String(decoding: standardError, as: UTF8.self) }
    }

    static func capture(in folder: URL, _ operation: () async throws -> Void) async throws -> Streams {
        let outFile = folder.appendingPathComponent("captured-stdout.bin")
        let errFile = folder.appendingPathComponent("captured-stderr.bin")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outFile)
        let errHandle = try FileHandle(forWritingTo: errFile)
        fflush(nil)
        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        dup2(outHandle.fileDescriptor, STDOUT_FILENO)
        dup2(errHandle.fileDescriptor, STDERR_FILENO)
        var thrown: Error?
        do {
            try await operation()
        } catch {
            thrown = error
        }
        fflush(nil)
        dup2(savedOut, STDOUT_FILENO)
        dup2(savedErr, STDERR_FILENO)
        close(savedOut)
        close(savedErr)
        try? outHandle.close()
        try? errHandle.close()
        if let thrown { throw thrown }
        return Streams(standardOutput: try Data(contentsOf: outFile), standardError: try Data(contentsOf: errFile))
    }
}

final class FASTATextModePinTests: XCTestCase {
    /// Two records. The first holds 234 bases, so it wraps at 60 columns for `convert` and at 70 for the
    /// protein of `translate` and for the 90 bases `extract sequence` takes from it.
    static let inputFASTA = [
        ">seqA first record",
        "ATGGCCATTGTAATGGGCCGCTGATAGCTAGCTAGGATCCGATCGATCGTAGCTAGCTAGCATCGATCGATGCTAGCTAGCATGCATGCTAGCTAAGGCTTAGGCC"
            + "ATCGGATAGCTTAGCGCGATATCGGATCGATTAGGCTAACGGATCCATGGCCTTAAGGCCTTAACCGGTTAAGCTAGCTAGGATATCGCGATCGATCGGCTAAGCTT"
            + "AGGCCAATTGGCCAATTGGCC",
        ">seqB",
        "ATGAAACCCGGGTTTTAAGGGCCCAAATTTGGGCCCATGCATGCATGCAT",
    ].joined(separator: "\n") + "\n"

    /// What `convert` writes for that input, 60 bases to a line.
    static let convertedFASTA = [
        ">seqA first record",
        "ATGGCCATTGTAATGGGCCGCTGATAGCTAGCTAGGATCCGATCGATCGTAGCTAGCTAG",
        "CATCGATCGATGCTAGCTAGCATGCATGCTAGCTAAGGCTTAGGCCATCGGATAGCTTAG",
        "CGCGATATCGGATCGATTAGGCTAACGGATCCATGGCCTTAAGGCCTTAACCGGTTAAGC",
        "TAGCTAGGATATCGCGATCGATCGGCTAAGCTTAGGCCAATTGGCCAATTGGCC",
        ">seqB",
        "ATGAAACCCGGGTTTTAAGGGCCCAAATTTGGGCCCATGCATGCATGCAT",
    ].joined(separator: "\n") + "\n"

    /// What `translate --frame 1` writes, 70 residues to a line.
    static let translatedFASTA = [
        ">seqA_frame+1 [Standard] [78 aa]",
        "MAIVMGR**LARIRSIVAS*HRSMLASMHAS*GLGHRIA*RDIGSIRLTDPWP*GLNRLS*LGYRDRSAK",
        "LRPIGQLA",
        ">seqB_frame+1 [Standard] [16 aa]",
        "MKPGF*GPKFGPMHAC",
    ].joined(separator: "\n") + "\n"

    /// What `extract sequence seqA:1-90` writes, 70 bases to a line.
    static let extractedFASTA = [
        ">seqA:1-90 [seqA:1-90, 1-based] [90 bp]",
        "ATGGCCATTGTAATGGGCCGCTGATAGCTAGCTAGGATCCGATCGATCGTAGCTAGCTAGCATCGATCGA",
        "TGCTAGCTAGCATGCATGCT",
    ].joined(separator: "\n") + "\n"

    static let translatingLine = "ℹ Translating two.fasta using Standard code (table 1)...\n"
    static let extractingLine = "ℹ Extracting seqA:1-90 from two.fasta...\n"

    private var folder: URL!
    private var input: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "fasta-text-pins")
        let captured = folder!
        addTeardownBlock { TestTempDirectory.cleanup(captured) }
        input = folder.appendingPathComponent("two.fasta")
        try Data(Self.inputFASTA.utf8).write(to: input)
    }

    // MARK: convert

    func testConvertWritesTheFASTAFileAndItsTwoTextLinesOnStandardOutput() async throws {
        let output = folder.appendingPathComponent("copy.fa")
        let command = try ConvertCommand.parse([input.path, "--to", output.path, "--no-color"])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        XCTAssertEqual(try Data(contentsOf: output), Data(Self.convertedFASTA.utf8))
        XCTAssertEqual(
            streams.standardOutputText,
            "ℹ Converting two.fasta to FASTA...\n✓ Converted 2 sequence(s) to copy.fa\n"
        )
        XCTAssertEqual(streams.standardErrorText, "")
    }

    // MARK: translate

    func testTranslateWritesTheFASTAToAFileAndItsSuccessLineOnStandardOutput() async throws {
        let output = folder.appendingPathComponent("protein.fa")
        let command = try TranslateCommand.parse([input.path, "--frame", "1", "-o", output.path, "--no-color"])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        XCTAssertEqual(try Data(contentsOf: output), Data(Self.translatedFASTA.utf8))
        XCTAssertEqual(streams.standardOutputText, "✓ Wrote 2 translation(s) from 2 sequence(s) to \(output.path)\n")
        XCTAssertEqual(streams.standardErrorText, Self.translatingLine)
    }

    func testTranslateWritesTheFASTAToStandardOutputWhenNoFileIsGiven() async throws {
        let command = try TranslateCommand.parse([input.path, "--frame", "1", "--no-color"])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        XCTAssertEqual(streams.standardOutput, Data(Self.translatedFASTA.utf8))
        XCTAssertEqual(streams.standardErrorText, Self.translatingLine)
    }

    // MARK: extract sequence

    func testExtractSequenceWritesTheFASTAToAFileAndItsSuccessLineOnStandardOutput() async throws {
        let output = folder.appendingPathComponent("region.fa")
        let command = try ExtractSequenceSubcommand.parse([input.path, "seqA:1-90", "-o", output.path, "--no-color"])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        XCTAssertEqual(try Data(contentsOf: output), Data(Self.extractedFASTA.utf8))
        XCTAssertEqual(streams.standardOutputText, "✓ Extracted 90 bp to \(output.path)\n")
        XCTAssertEqual(streams.standardErrorText, Self.extractingLine)
    }

    func testExtractSequenceWritesTheFASTAToStandardOutputWhenNoFileIsGiven() async throws {
        let command = try ExtractSequenceSubcommand.parse([input.path, "seqA:1-90", "--no-color"])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        XCTAssertEqual(streams.standardOutput, Data(Self.extractedFASTA.utf8))
        XCTAssertEqual(streams.standardErrorText, Self.extractingLine + "ℹ Extracted 90 bp:\n")
    }
}
