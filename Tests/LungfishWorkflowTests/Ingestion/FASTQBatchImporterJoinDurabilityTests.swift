// FASTQBatchImporterJoinDurabilityTests.swift - The importer's join fails with an error and publishes whole
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.10 lane S31, M3. The batch importer joins the unmerged and merged
/// FASTQ files bbmerge writes into one file. At the base it read each source
/// whole with `fm.contents(atPath:)` and skipped one it could not read, so a
/// joined file could hold fewer reads than its sources with no error (panel
/// BIO 2), and a multi-gigabyte source was loaded whole (SWIFT 5). The join
/// now streams each source in chunks, fails with an error that names the
/// source it could not read, and publishes through `DurableReplace`.
///
/// The class name holds `Durability`, so `exfat-tests.sh --simulate` runs it
/// with every rename taking its ExFAT fallback. The byte pins are
/// `FASTQBatchImporterJoinBytePinTests`.
final class FASTQBatchImporterJoinDurabilityTests: XCTestCase {
    private typealias Fixtures = ReadWriterFixtures
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "importer-join-durability")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func member(_ name: String, fileName: String) throws -> URL {
        try Fixtures.write(Fixtures.fastq(name), named: fileName, in: root)
    }

    private func entries() throws -> [String] {
        try Fixtures.entries(of: root)
    }

    private func assertNames(_ error: Error?, _ source: URL, file: StaticString = #filePath, line: UInt = #line) {
        guard case .unreadableSource(let path, _)? = error as? ReadFileWriterError else {
            return XCTFail("expected an unreadable source error, got \(String(describing: error))", file: file, line: line)
        }
        XCTAssertEqual(path, source.path, file: file, line: line)
        XCTAssertTrue(
            (error?.localizedDescription ?? "").contains(source.lastPathComponent),
            "the message names the file: \(String(describing: error?.localizedDescription))",
            file: file,
            line: line
        )
        XCTAssertFalse((error?.localizedDescription ?? "").contains(".."), "the reason ends with one period", file: file, line: line)
    }

    // MARK: - A source that cannot be read

    /// The base skipped this source, wrote the other two and returned.
    func testAMissingSourceIsAnErrorThatNamesItAndNoJoinedFileIsWritten() throws {
        let first = try member("a1", fileName: "a.fastq")
        let missing = root.appendingPathComponent("gone.fastq")
        let third = try member("c1", fileName: "c.fastq")
        let destination = root.appendingPathComponent("joined.fastq")
        var thrown: Error?

        do {
            try FASTQBatchImporter.concatenateFiles([first, missing, third], to: destination)
        } catch {
            thrown = error
        }

        assertNames(thrown, missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a failed join names no file")
        XCTAssertEqual(try entries(), ["a.fastq", "c.fastq"], "no stage file is left")
    }

    /// A directory opens but cannot be read, so the failure comes from the
    /// read, after the first source went out.
    func testASourceThatIsAFolderIsAnErrorThatNamesItAndKeepsTheOldJoinedFile() throws {
        let first = try member("a1", fileName: "a.fastq")
        let folder = root.appendingPathComponent("sub.fastq", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try Fixtures.write(Data("old\n".utf8), named: "joined.fastq", in: root)
        var thrown: Error?

        do {
            try FASTQBatchImporter.concatenateFiles([first, folder], to: destination)
        } catch {
            thrown = error
        }

        assertNames(thrown, folder)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old\n".utf8))
        XCTAssertEqual(try entries(), ["a.fastq", "joined.fastq", "sub.fastq"], "no stage file is left")
    }

    func testASourceWithNoReadPermissionIsAnErrorThatNamesItAndKeepsTheOldJoinedFile() throws {
        try XCTSkipIf(getuid() == 0, "root reads a file whatever its mode")
        let first = try member("a1", fileName: "a.fastq")
        let locked = try member("b1", fileName: "b.fastq")
        let destination = try Fixtures.write(Data("old\n".utf8), named: "joined.fastq", in: root)
        XCTAssertEqual(chmod(locked.path, 0o000), 0)
        defer { chmod(locked.path, 0o644) }
        var thrown: Error?

        do {
            try FASTQBatchImporter.concatenateFiles([first, locked], to: destination)
        } catch {
            thrown = error
        }

        assertNames(thrown, locked)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old\n".utf8))
    }

    // MARK: - Faults and durability

    func testAFullDiskIsAThrownErrorAndTheNameKeepsItsOldFile() throws {
        let sources = [try member("a1", fileName: "a.fastq"), try member("b1", fileName: "b.fastq"), try member("c1", fileName: "c.fastq")]
        let destination = try Fixtures.write(Data("old\n".utf8), named: "joined.fastq", in: root)
        let tally = Fixtures.Tally()

        XCTAssertThrowsError(
            try DurableReplace.$overrideOperations.withValue(Fixtures.fullDisk(afterWrites: 1, tally: tally)) {
                try FASTQBatchImporter.concatenateFiles(sources, to: destination)
            }
        ) { Fixtures.assertFullDisk($0) }

        XCTAssertEqual(tally["stageWrites"], 2, "the write after the failure never ran")
        XCTAssertEqual(try Data(contentsOf: destination), Data("old\n".utf8))
        XCTAssertEqual(try entries(), ["a.fastq", "b.fastq", "c.fastq", "joined.fastq"], "no stage file is left")
    }

    func testTheJoinedFileIsSyncedBeforeItIsNamed() throws {
        let sources = [try member("a1", fileName: "a.fastq"), try member("b1", fileName: "b.fastq")]
        let destination = root.appendingPathComponent("joined.fastq")
        let tally = Fixtures.Tally()
        let operations = DurableReplace.Operations(
            syncFile: { tally.add("syncFile"); return Darwin.fsync($0) },
            checkpoint: { tally.add($0.rawValue) }
        )

        try DurableReplace.$overrideOperations.withValue(operations) {
            try FASTQBatchImporter.concatenateFiles(sources, to: destination)
        }

        XCTAssertEqual(tally["syncFile"], 1, "one fsync of the file")
        XCTAssertEqual(tally["stageSynced"], 1)
        XCTAssertEqual(tally["published"], 1)
        XCTAssertEqual(try entries(), ["a.fastq", "b.fastq", "joined.fastq"])
    }

    /// The base read a source whole, so its bytes went out in one write.
    func testALargeSourceIsStreamedInChunksAndNeverHeldWhole() throws {
        let chunk = ReadFileWriters.chunkSize
        let large = try Fixtures.write(
            Data(repeating: UInt8(ascii: "A"), count: 2 * chunk + 1),
            named: "large.fastq",
            in: root
        )
        let destination = root.appendingPathComponent("joined.fastq")
        let tally = Fixtures.Tally()
        let operations = DurableReplace.Operations(writeBytes: { descriptor, bytes, count in
            if Fixtures.path(of: descriptor).contains(DurableReplace.stageInfix) {
                tally.add("stageWrites")
                if count > chunk { tally.add("oversizedWrites") }
            }
            return Darwin.write(descriptor, bytes, count)
        })

        try DurableReplace.$overrideOperations.withValue(operations) {
            try FASTQBatchImporter.concatenateFiles([large], to: destination)
        }

        XCTAssertEqual(tally["stageWrites"], 3, "two whole chunks and the one byte left")
        XCTAssertEqual(tally["oversizedWrites"], 0, "no write is larger than a chunk")
        XCTAssertEqual(try Data(contentsOf: destination).count, 2 * chunk + 1)
    }
}
