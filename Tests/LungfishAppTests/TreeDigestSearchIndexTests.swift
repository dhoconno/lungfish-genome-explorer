// TreeDigestSearchIndexTests.swift - What the reveal tests' TreeDigest counts (Phase 2.11 tier 1, cause D3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport

/// `TreeDigest` backs the claim of the reveal tests that a display and a reveal write nothing into the project.
/// Opening a project and every rescan of the sidebar schedule a rebuild of the project's universal search index
/// (`SidebarViewController.scheduleUniversalSearchRebuild`, 0.05 s and 0.75 s later), and that rebuild writes
/// `.universal-search.db` with its `-wal` and `-shm` files. Under load the rebuild landed between the two digests of
/// `PrimerTrimInspectorAfterRevealTests`, so the unit tier failed on files that neither the display nor the reveal
/// wrote. The digest leaves out the search index's own files and still counts every other file.
final class TreeDigestSearchIndexTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "tree-digest-search-index")
    }

    override func tearDownWithError() throws {
        if let folder { TestTempDirectory.cleanup(folder) }
    }

    func testTheDigestLeavesOutTheFilesTheProjectSearchIndexWrites() throws {
        try Data("reference".utf8).write(to: folder.appendingPathComponent("Reference.fasta"))
        let before = try TreeDigest.of(folder)

        // The open index keeps its WAL and shared memory files, as they are while the indexer's connection lives.
        let index = try ProjectUniversalSearchIndex(projectURL: folder)
        try index.rebuild()
        try withExtendedLifetime(index) {
            let indexFiles = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .filter { $0.hasPrefix(".universal-search.db") }
                .sorted()
            XCTAssertTrue(
                indexFiles.contains(".universal-search.db"),
                "precondition: the index wrote its database, the folder holds \(indexFiles)"
            )
            XCTAssertEqual(
                try TreeDigest.of(folder), before,
                "the digest counts \(indexFiles), which the indexer writes and a display or a reveal does not"
            )
        }
    }

    func testTheDigestStillSeesEveryFileADisplayOrRevealCouldWrite() throws {
        let reference = folder.appendingPathComponent("Reference.fasta")
        try Data("reference".utf8).write(to: reference)
        let original = try TreeDigest.of(folder)

        try Data("changed".utf8).write(to: reference)
        XCTAssertNotEqual(try TreeDigest.of(folder), original, "a changed file")
        try Data("reference".utf8).write(to: reference)
        XCTAssertEqual(try TreeDigest.of(folder), original, "the digest returns once the file is restored")

        let sidecar = folder.appendingPathComponent("Reference.fasta.lungfish-meta.json")
        try Data("{}".utf8).write(to: sidecar)
        XCTAssertNotEqual(try TreeDigest.of(folder), original, "an added sidecar")
        try FileManager.default.removeItem(at: sidecar)
        XCTAssertEqual(try TreeDigest.of(folder), original, "the digest returns once the sidecar is removed")

        try FileManager.default.removeItem(at: reference)
        XCTAssertNotEqual(try TreeDigest.of(folder), original, "a removed file")
    }
}
