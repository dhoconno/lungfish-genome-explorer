// BuildDbSnapshotRestoreDurabilityTests.swift - A build-db rebuild that stops puts the earlier database back without emptying its name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// What `BuildDbDatabaseSnapshot.restore()` leaves in a result folder (lane S33, 2.8 row 266). A `build-db`
/// core captures the database, its journal, its shared-memory file and its record before a rebuild and
/// restores them when the rebuild fails or is cancelled. The class name holds `Durability`, so
/// `exfat-tests.sh --simulate` runs it with every flagged rename taking its ExFAT fallback.
final class BuildDbSnapshotRestoreDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "build-db-snapshot")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: What a restore puts back

    /// A rebuild of a folder that held every file puts every file back.
    func testARestorePutsBackEveryFileTheSnapshotHeld() throws {
        try assertRestore(whenTheEarlierBuildHeld: Set(Kind.allCases))
    }

    /// A rebuild of a folder that held the database and its record, which the rebuild's journal and
    /// shared-memory file are not part of, removes what the rebuild wrote beside them.
    func testARestoreRemovesTheFilesTheRebuildAddedToTheSnapshot() throws {
        try assertRestore(whenTheEarlierBuildHeld: [.database, .record])
    }

    /// A first build has nothing to put back, so the restore leaves the folder without the build's files.
    func testARestoreOfAFirstBuildRemovesEverythingTheBuildWrote() throws {
        try assertRestore(whenTheEarlierBuildHeld: [])
    }

    // MARK: What a restore that stops loses

    /// The restore removes the database, journal, shared-memory file and record first and copies the
    /// captured files back afterwards, so a restore that stops between the two (a copy that fails, or a
    /// crash) leaves the folder without the earlier database and without the rebuild's. The snapshot is
    /// gone here, as when the temporary folder holding it is cleaned, so the copy cannot read it. This pins
    /// the loss at the base, and lane S33 M2 turns it into a restore that removes nothing it cannot put back.
    func testARestoreThatStopsAfterTheRemoveLeavesNoDatabase() throws {
        let files = Files(in: try folder("stops-after-the-remove"))
        try write("earlier database", to: files.database)
        try write("earlier record", to: files.record)
        let snapshot = try BuildDbDatabaseSnapshot.capture(dbURL: files.database)
        try write("rebuilt database", to: files.database)
        try write("rebuilt record", to: files.record)
        try snapshot.discard()

        XCTAssertThrowsError(try snapshot.restore(), "The copy cannot read the snapshot")

        for kind in Kind.allCases {
            XCTAssertNil(try read(files.url(kind)), "\(kind) was removed and nothing was copied back")
        }
    }

    // MARK: Helpers

    /// The files of one database in a result folder.
    private enum Kind: String, CaseIterable {
        case database, journal, sharedMemory, record
    }

    private struct Files {
        let database: URL
        let journal: URL
        let sharedMemory: URL
        let record: URL

        init(in folder: URL) {
            database = folder.appendingPathComponent("esviritu.sqlite")
            journal = URL(fileURLWithPath: database.path + "-wal")
            sharedMemory = URL(fileURLWithPath: database.path + "-shm")
            record = ProvenanceRecorder.fileSidecarURL(for: database)
        }

        func url(_ kind: Kind) -> URL {
            switch kind {
            case .database: return database
            case .journal: return journal
            case .sharedMemory: return sharedMemory
            case .record: return record
            }
        }
    }

    /// Captures a folder that holds the `held` files of an earlier build, lets a rebuild write every file
    /// with other bytes, restores, and expects the earlier bytes back for each held file and nothing for
    /// each other file.
    private func assertRestore(
        whenTheEarlierBuildHeld held: Set<Kind>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let files = Files(in: try folder("restore-\(held.map(\.rawValue).sorted().joined(separator: "-"))"))
        for kind in held {
            try write("earlier \(kind.rawValue)", to: files.url(kind))
        }
        let snapshot = try BuildDbDatabaseSnapshot.capture(dbURL: files.database)
        for kind in Kind.allCases {
            try write("rebuilt \(kind.rawValue)", to: files.url(kind))
        }

        try snapshot.restore()

        for kind in Kind.allCases {
            XCTAssertEqual(
                try read(files.url(kind)), held.contains(kind) ? "earlier \(kind.rawValue)" : nil,
                "\(kind) after a restore", file: file, line: line
            )
        }
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    /// The text of the file at `url`, or `nil` when it holds nothing.
    private func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
}
