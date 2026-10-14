// FASTQBatchImporterJoinBytePinTests.swift - Output bytes of the importer's join of FASTQ files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.10 lane S31, M1. The bytes of the join the batch importer makes
/// of the files bbmerge writes, pinned for the same members and cases as the
/// resolver's and the materializer's joins (`ReadWriterBytePinTests`). The
/// join was private to the importer at the base, so these pins start at the
/// move that made it reachable, and they pass again after M3 streams it.
final class FASTQBatchImporterJoinBytePinTests: XCTestCase {
    private typealias Fixtures = ReadWriterFixtures
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "importer-join-pins")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testTheImporterJoinsByteForByte() throws {
        for (index, joinCase) in try Fixtures.joinCases().enumerated() {
            let staged = try Fixtures.stage(joinCase, in: root.appendingPathComponent("join-\(index)", isDirectory: true))
            try FASTQBatchImporter.concatenateFiles(staged.sources, to: staged.destination)
            try Fixtures.check(joinCase, destination: staged.destination)
        }
    }

    func testTheImporterJoinReplacesAnExistingDestinationWithExactlyTheNewBytes() throws {
        let folder = root.appendingPathComponent("replace", isDirectory: true)
        let source = try Fixtures.write(Fixtures.fastq("new"), named: "new.fastq", in: folder)
        let destination = try Fixtures.write(Data(repeating: UInt8(ascii: "X"), count: 4096), named: "joined.fastq", in: folder)

        try FASTQBatchImporter.concatenateFiles([source], to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Fixtures.fastq("new"))
    }

    func testTheImporterJoinWritesAnEmptyFileForNoSources() throws {
        let folder = root.appendingPathComponent("none", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("joined.fastq")

        try FASTQBatchImporter.concatenateFiles([], to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data())
    }
}
