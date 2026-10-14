// FASTQCLIMaterializerWriterDurabilityTests.swift - The materializer's writers fail with an error and publish whole
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

/// Phase 2.10 lane S31, M2. The FASTQ materializer's join and its two FASTA
/// writers over root files put their bytes in a hidden stage file and name
/// the result only when it is whole and synced. A failed write, a full disk
/// among them, is a thrown error, where `FileHandle.write(_:)` raised an
/// Objective-C exception that Swift cannot catch. A part file never sits
/// under the final name, and the name keeps its old file when a writer fails.
///
/// The class name holds `Durability`, so `exfat-tests.sh --simulate` runs it
/// with every rename taking its ExFAT fallback. The byte pins are
/// `ReadWriterBytePinTests`.
final class FASTQCLIMaterializerWriterDurabilityTests: XCTestCase {
    private typealias Fixtures = ReadWriterFixtures
    private var root: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "materializer-writer-durability")
        folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func entries() throws -> [String] {
        try Fixtures.entries(of: folder)
    }

    private func member(_ names: String..., fileName: String) throws -> URL {
        try Fixtures.write(Data(names.map { "@\($0)\nACGT\n+\nIIII\n" }.joined().utf8), named: fileName, in: folder)
    }

    // MARK: - The materializer's join

    func testAFullDiskDuringTheMaterializersJoinIsAThrownErrorAndTheNameKeepsItsOldFile() throws {
        let sources = [try member("a1", fileName: "a.fastq"), try member("b1", fileName: "b.fastq")]
        let destination = try Fixtures.write(Data("old\n".utf8), named: "joined.fastq", in: folder)
        let tally = Fixtures.Tally()

        XCTAssertThrowsError(
            try DurableReplace.$overrideOperations.withValue(Fixtures.fullDisk(afterWrites: 1, tally: tally)) {
                try FASTQCLIMaterializer(runner: .shared).concatenateFiles(sources, to: destination)
            }
        ) { Fixtures.assertFullDisk($0) }

        XCTAssertEqual(try Data(contentsOf: destination), Data("old\n".utf8))
        XCTAssertEqual(try entries(), ["a.fastq", "b.fastq", "joined.fastq"], "no stage file is left")
    }

    func testAMissingLaterSourceLeavesNothingUnderTheMaterializersFinalName() throws {
        let present = try member("a1", fileName: "a.fastq")
        let fresh = folder.appendingPathComponent("fresh.fastq")
        let old = try Fixtures.write(Data("old\n".utf8), named: "old.fastq", in: folder)
        let materializer = FASTQCLIMaterializer(runner: .shared)
        let missing = folder.appendingPathComponent("gone.fastq")

        XCTAssertThrowsError(try materializer.concatenateFiles([present, missing], to: fresh))
        XCTAssertThrowsError(try materializer.concatenateFiles([present, missing], to: old))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path), "a failed join names no file")
        XCTAssertEqual(try Data(contentsOf: old), Data("old\n".utf8))
        XCTAssertEqual(try entries(), ["a.fastq", "old.fastq"], "no stage file is left")
    }

    // MARK: - FASTA from root files

    private func makeRoots(_ texts: String...) throws -> [URL] {
        try texts.enumerated().map { index, text in
            try Fixtures.write(Data(text.utf8), named: "root\(index).fasta", in: folder.appendingPathComponent("roots", isDirectory: true))
        }
    }

    private func outputFolder() throws -> URL {
        let url = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAFullDiskDuringTheTrimmedFASTAWriteIsAThrownErrorAndKeepsTheOldFile() async throws {
        let roots = try makeRoots(">r1\nAACCGGTT\n", ">r2\nTTGGCCAA\n")
        let output = try Fixtures.write(Data(">old\nAC\n".utf8), named: "reads.fasta", in: try outputFolder())
        let tally = Fixtures.Tally()
        let operations = Fixtures.fullDisk(afterWrites: 0, tally: tally)

        let error = await Fixtures.capturedError {
            try await DurableReplace.$overrideOperations.withValue(operations) {
                try await FASTQCLIMaterializer(runner: .shared).extractTrimmedFASTAReads(
                    fromRootFASTAs: roots,
                    positions: ["r1": (start: 0, end: 4), "r2": (start: 0, end: 4)],
                    outputFASTA: output
                )
            }
        }

        Fixtures.assertFullDisk(error)
        XCTAssertEqual(tally["stageWrites"], 1, "the write after the failure never ran")
        XCTAssertEqual(try Data(contentsOf: output), Data(">old\nAC\n".utf8))
        XCTAssertEqual(try Fixtures.entries(of: output.deletingLastPathComponent()), ["reads.fasta"])
    }

    func testAFullDiskDuringTheOrientedFASTAWriteIsAThrownErrorAndNamesNoFile() async throws {
        let roots = try makeRoots(">r1\nAACCGGTT\n", ">r2\nTTGGCCAA\n")
        let directory = try outputFolder()
        let output = directory.appendingPathComponent("oriented.fasta")
        let operations = Fixtures.fullDisk(afterWrites: 0, tally: Fixtures.Tally())

        let error = await Fixtures.capturedError {
            try await DurableReplace.$overrideOperations.withValue(operations) {
                try await FASTQCLIMaterializer(runner: .shared).materializeOrientedFASTAReads(
                    fromRootFASTAs: roots,
                    allReadIDs: ["r1", "r2"],
                    rcReadIDs: ["r2"],
                    outputFASTA: output
                )
            }
        }

        Fixtures.assertFullDisk(error)
        XCTAssertEqual(try Fixtures.entries(of: directory), [], "neither the file nor a stage file is left")
    }

    func testAMissingLaterRootFileLeavesNoPartFASTAUnderTheFinalName() async throws {
        let present = try makeRoots(">r1\nAACCGGTT\n")
        let missing = folder.appendingPathComponent("roots/gone.fasta")
        let directory = try outputFolder()
        let materializer = FASTQCLIMaterializer(runner: .shared)

        let trimmedError = await Fixtures.capturedError {
            try await materializer.extractTrimmedFASTAReads(
                fromRootFASTAs: present + [missing],
                positions: ["r1": (start: 0, end: 4)],
                outputFASTA: directory.appendingPathComponent("trimmed.fasta")
            )
        }
        let orientedError = await Fixtures.capturedError {
            try await materializer.materializeOrientedFASTAReads(
                fromRootFASTAs: present + [missing],
                allReadIDs: ["r1"],
                rcReadIDs: [],
                outputFASTA: directory.appendingPathComponent("oriented.fasta")
            )
        }

        XCTAssertNotNil(trimmedError)
        XCTAssertNotNil(orientedError)
        XCTAssertEqual(try Fixtures.entries(of: directory), [], "a failed write names no file")
    }

    func testTheFASTAWritersSyncTheirOutputBeforeNamingIt() async throws {
        let roots = try makeRoots(">r1\nAACCGGTT\n", ">r2\nTTGGCCAA\n")
        let directory = try outputFolder()
        let tally = Fixtures.Tally()
        let operations = DurableReplace.Operations(syncFile: { tally.add("syncFile"); return Darwin.fsync($0) })

        try await DurableReplace.$overrideOperations.withValue(operations) {
            let materializer = FASTQCLIMaterializer(runner: .shared)
            try await materializer.extractTrimmedFASTAReads(
                fromRootFASTAs: roots,
                positions: ["r1": (start: 0, end: 4)],
                outputFASTA: directory.appendingPathComponent("trimmed.fasta")
            )
            try await materializer.materializeOrientedFASTAReads(
                fromRootFASTAs: roots,
                allReadIDs: ["r1", "r2"],
                rcReadIDs: ["r2"],
                outputFASTA: directory.appendingPathComponent("oriented.fasta")
            )
        }

        XCTAssertEqual(tally["syncFile"], 2, "one fsync for each output file")
        XCTAssertEqual(try Fixtures.entries(of: directory), ["oriented.fasta", "trimmed.fasta"])
    }
}
