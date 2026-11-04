// SidebarBlastSearchFolderTests.swift - A BLAST search folder stays out of the sidebar until its record exists
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTCOLLECT (BLAST-FAILED-LEFTOVERS, UX-BLAST-WORDS item 10 and the backlog row). A search that waits for hours,
// or that ended with no result, left a folder of `query.fasta` and a provenance file in the sidebar, which read as a
// result with nothing in it. Words are checked by meaning.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishTestSupport

final class SidebarBlastSearchFolderTests: XCTestCase {
    private func searchFile() -> BlastSearchFile {
        let request = BlastVerificationRequest(taxonName: "Taxon", taxId: 7, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt")
        return BlastSearchFile(
            origin: .standIn, createdAt: Date(), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
    }

    /// Every file or folder name the sidebar lists for `project`, at any depth.
    private func listedNames(in project: URL) -> Set<String> {
        func names(_ nodes: [SidebarScanNode]) -> [String] {
            nodes.flatMap { node in [node.url?.lastPathComponent].compactMap { $0 } + names(node.children) }
        }
        return Set(names(SidebarProjectScanner.scanRootNodes(from: project)))
    }

    @MainActor
    func testASearchFolderStaysOutOfTheSidebarUntilItsRecordExists() throws {
        let root = try TestTempDirectory.make(prefix: "sidebar-blast-search")
        defer { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let search = project.appendingPathComponent("blast-verifications/Taxon-2026-11-01T21-52-25-d352b15d", isDirectory: true)
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        try "query".write(to: search.appendingPathComponent("query.fasta"), atomically: true, encoding: .utf8)
        try BlastSearchStore(folder: search).save(searchFile())

        XCTAssertFalse(
            SidebarProjectScanner.shouldIncludeEntry(search, isDirectory: true, context: .regularDirectory),
            "a search with no result is no result folder"
        )
        XCTAssertFalse(listedNames(in: project).contains(search.lastPathComponent))

        try Data("{}".utf8).write(to: search.appendingPathComponent(BlastSubmissionRecord.recordFileName))
        XCTAssertTrue(
            SidebarProjectScanner.shouldIncludeEntry(search, isDirectory: true, context: .regularDirectory),
            "the folder shows once its record exists"
        )
        XCTAssertTrue(listedNames(in: project).contains(search.lastPathComponent))
    }

    @MainActor
    func testAFolderWithNoSearchFileIsListedAsBefore() throws {
        let root = try TestTempDirectory.make(prefix: "sidebar-blast-plain")
        defer { TestTempDirectory.cleanup(root) }
        let folder = root.appendingPathComponent("Fixture.lungfish/blast-verifications/older-run", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "query".write(to: folder.appendingPathComponent("query.fasta"), atomically: true, encoding: .utf8)

        XCTAssertTrue(SidebarProjectScanner.shouldIncludeEntry(folder, isDirectory: true, context: .regularDirectory))
        XCTAssertFalse(SidebarProjectScanner.isIncompleteOutput(folder), "only a folder that holds a search file is held back")
    }
}
