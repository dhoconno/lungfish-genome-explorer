// ReadWriterDurabilityTests.swift - The read writers fail with an error and publish whole
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

/// Phase 2.10 lane S31, M2. The classifier read resolver's and the FASTQ
/// materializer's writers put their bytes in a hidden stage file and name the
/// result only when it is whole and synced. A failed write, a full disk among
/// them, is a thrown error, where `FileHandle.write(_:)` raised an Objective-C
/// exception that Swift cannot catch. A part file never sits under the final
/// name, and the name keeps its old file when a writer fails.
///
/// The class name holds `Durability`, so `exfat-tests.sh --simulate` runs it
/// with every rename taking its ExFAT fallback. The byte pins are
/// `ReadWriterBytePinTests`.
final class ReadWriterDurabilityTests: XCTestCase {
    private typealias Fixtures = ReadWriterFixtures
    private var root: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "read-writer-durability")
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

    // MARK: - The resolver's join

    func testAFullDiskDuringTheResolversJoinIsAThrownErrorAndTheNameKeepsItsOldFile() async throws {
        let sources = [try member("a1", fileName: "a.fastq"), try member("b1", fileName: "b.fastq"), try member("c1", fileName: "c.fastq")]
        let destination = try Fixtures.write(Data("old\n".utf8), named: "joined.fastq", in: folder)
        let tally = Fixtures.Tally()
        let operations = Fixtures.fullDisk(afterWrites: 1, tally: tally)

        let error = await Fixtures.capturedError {
            try await DurableReplace.$overrideOperations.withValue(operations) {
                try await ClassifierReadResolver().concatenateFiles(sources, into: destination)
            }
        }

        Fixtures.assertFullDisk(error)
        XCTAssertEqual(tally["stageWrites"], 2, "the write after the failure never ran")
        XCTAssertEqual(try Data(contentsOf: destination), Data("old\n".utf8))
        XCTAssertEqual(try entries(), ["a.fastq", "b.fastq", "c.fastq", "joined.fastq"], "no stage file is left")
    }

    func testAMissingLaterSourceLeavesNothingUnderTheFinalNameAndKeepsTheOldFile() async throws {
        let present = try member("a1", fileName: "a.fastq")
        let missing = folder.appendingPathComponent("gone.fastq")
        let fresh = folder.appendingPathComponent("fresh.fastq")
        let old = try Fixtures.write(Data("old\n".utf8), named: "old.fastq", in: folder)
        let resolver = ClassifierReadResolver()

        let freshError = await Fixtures.capturedError { try await resolver.concatenateFiles([present, missing], into: fresh) }
        let oldError = await Fixtures.capturedError { try await resolver.concatenateFiles([present, missing], into: old) }

        XCTAssertNotNil(freshError)
        XCTAssertNotNil(oldError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path), "a failed join names no file")
        XCTAssertEqual(try Data(contentsOf: old), Data("old\n".utf8))
        XCTAssertEqual(try entries(), ["a.fastq", "old.fastq"], "no stage file is left")
    }

    func testTheResolversJoinIsSyncedBeforeItIsNamedAndLeavesNoStageFile() async throws {
        let sources = [try member("a1", fileName: "a.fastq"), try member("b1", fileName: "b.fastq")]
        let destination = folder.appendingPathComponent("joined.fastq")
        let tally = Fixtures.Tally()
        let operations = DurableReplace.Operations(
            syncFile: { tally.add("syncFile"); return Darwin.fsync($0) },
            checkpoint: { tally.add($0.rawValue) }
        )

        try await DurableReplace.$overrideOperations.withValue(operations) {
            try await ClassifierReadResolver().concatenateFiles(sources, into: destination)
        }

        XCTAssertEqual(tally["syncFile"], 1, "one fsync of the file")
        XCTAssertEqual(tally["stageSynced"], 1)
        XCTAssertEqual(tally["published"], 1)
        XCTAssertEqual(try entries(), ["a.fastq", "b.fastq", "joined.fastq"])
    }

    func testTheFinalNameStaysAbsentWhileTheResolverStillStreams() async throws {
        let sources = [try member("a1", fileName: "a.fastq"), try member("b1", fileName: "b.fastq")]
        let destination = folder.appendingPathComponent("joined.fastq")
        let seen = Fixtures.Tally()
        let directory = folder.path
        let operations = DurableReplace.Operations(writeBytes: { descriptor, bytes, count in
            if Fixtures.path(of: descriptor).contains(DurableReplace.stageInfix), seen.add("writes") == 2 {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
                if names.contains("joined.fastq") { seen.add("finalNameVisible") }
                if names.contains(where: { $0.hasPrefix(".") && $0.contains(DurableReplace.stageInfix) }) { seen.add("stageVisible") }
            }
            return Darwin.write(descriptor, bytes, count)
        })

        try await DurableReplace.$overrideOperations.withValue(operations) {
            try await ClassifierReadResolver().concatenateFiles(sources, into: destination)
        }

        XCTAssertEqual(seen["writes"], 2)
        XCTAssertEqual(seen["finalNameVisible"], 0, "the final name appears only when the file is whole")
        XCTAssertEqual(seen["stageVisible"], 1, "the bytes stream into a hidden stage")
    }

    // MARK: - FASTQ to FASTA

    func testAFullDiskDuringTheConversionIsAThrownErrorAndTheNameKeepsItsOldFile() async throws {
        let input = try member("r1", "r2", fileName: "in.fastq")
        let output = try Fixtures.write(Data(">old\nAC\n".utf8), named: "out.fasta", in: folder)
        let tally = Fixtures.Tally()
        let operations = Fixtures.fullDisk(afterWrites: 0, tally: tally)

        let error = await Fixtures.capturedError {
            try await DurableReplace.$overrideOperations.withValue(operations) {
                try await ClassifierReadResolver().convertFASTQToFASTA(input: input, output: output)
            }
        }

        Fixtures.assertFullDisk(error)
        XCTAssertEqual(try Data(contentsOf: output), Data(">old\nAC\n".utf8))
        XCTAssertEqual(try entries(), ["in.fastq", "out.fasta"], "no stage file is left")
    }

    func testAnInputThatCannotBeOpenedLeavesTheOldFASTAOutputInPlace() async throws {
        let output = try Fixtures.write(Data(">old\nAC\n".utf8), named: "out.fasta", in: folder)

        let error = await Fixtures.capturedError {
            try await ClassifierReadResolver().convertFASTQToFASTA(input: folder.appendingPathComponent("gone.fastq"), output: output)
        }

        XCTAssertNotNil(error)
        XCTAssertEqual(try Data(contentsOf: output), Data(">old\nAC\n".utf8))
        XCTAssertEqual(try entries(), ["out.fasta"])
    }

    func testTheConversionIsSyncedBeforeItIsNamed() async throws {
        let input = try member("r1", fileName: "in.fastq")
        let output = folder.appendingPathComponent("out.fasta")
        let tally = Fixtures.Tally()
        let operations = DurableReplace.Operations(syncFile: { tally.add("syncFile"); return Darwin.fsync($0) })

        try await DurableReplace.$overrideOperations.withValue(operations) {
            try await ClassifierReadResolver().convertFASTQToFASTA(input: input, output: output)
        }

        XCTAssertEqual(tally["syncFile"], 1)
        XCTAssertEqual(try Data(contentsOf: output), Data(">r1\nACGT\n".utf8))
        XCTAssertEqual(try entries(), ["in.fastq", "out.fasta"])
    }

}
