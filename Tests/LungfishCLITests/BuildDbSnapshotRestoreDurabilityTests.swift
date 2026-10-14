// BuildDbSnapshotRestoreDurabilityTests.swift - A build-db rebuild that stops puts the earlier database back without emptying its name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// What `BuildDbDatabaseSnapshot.restore()` leaves in a result folder (lane S33, 2.8 row 266). A `build-db`
/// core captures the database, its journal, its shared-memory file and its record before a rebuild and
/// restores them when the rebuild fails or is cancelled. The restore publishes each captured file through
/// `DurableReplace`, so a name holds a complete file at every step. The class name holds `Durability`, so
/// `exfat-tests.sh --simulate` runs it, and each case here runs natively and with every flagged rename
/// taking its ExFAT fallback.
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

    /// A rebuild of a folder that held the database and its record removes the journal and the
    /// shared-memory file that the rebuild wrote beside them.
    func testARestoreRemovesTheFilesTheRebuildAddedToTheSnapshot() throws {
        try assertRestore(whenTheEarlierBuildHeld: [.database, .record])
    }

    /// A first build has nothing to put back, so the restore leaves the folder without the build's files.
    func testARestoreOfAFirstBuildRemovesEverythingTheBuildWrote() throws {
        try assertRestore(whenTheEarlierBuildHeld: [])
    }

    // MARK: A restore that stops

    /// The restore used to remove the database, journal, shared-memory file and record first and copy the
    /// captured files back afterwards, so a restore that stopped between the two (a copy that failed, or a
    /// crash) left the folder without the earlier database and without the rebuild's. It now opens every
    /// captured copy before it changes a name, so a snapshot it cannot read ends it with the folder as the
    /// rebuild left it. The snapshot is gone here, as when the temporary folder holding it is cleaned.
    func testARestoreThatCannotReadTheSnapshotChangesNothing() throws {
        let rebuild = try seedRebuild("cannot-read", held: Set(Kind.allCases))
        try rebuild.snapshot.discard()

        XCTAssertThrowsError(try rebuild.snapshot.restore(), "The copy cannot read the snapshot")

        for kind in Kind.allCases {
            XCTAssertEqual(try read(rebuild.files.url(kind)), "rebuilt \(kind.rawValue)", "\(kind) was changed or removed")
        }
    }

    /// A first build has nothing to put back, so the restore removes each file the build wrote. A removal
    /// that fails is thrown, where the restore once hid it, the files stay as the build left them, and a
    /// second restore, once the folder can change, finishes the job.
    func testARestoreThatCannotRemoveAFileThrowsAndCanBeRunAgain() throws {
        let rebuild = try seedRebuild("cannot-remove", held: [])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rebuild.folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rebuild.folder.path) }

        XCTAssertThrowsError(try rebuild.snapshot.restore(), "The folder refused the removal")

        for kind in Kind.allCases {
            XCTAssertEqual(try read(rebuild.files.url(kind)), "rebuilt \(kind.rawValue)", "\(kind) was changed or removed")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rebuild.folder.path)
        try rebuild.snapshot.restore()
        try assertRestored(rebuild.files, "after a second restore", held: [])
    }

    /// Each captured file goes back as one `DurableReplace` publication, staged beside its name and swapped
    /// in, and the four publications share one flush.
    func testARestorePublishesEachCapturedFileThroughDurableReplace() throws {
        for simulated in [false, true] {
            let rebuild = try seedRebuild("publishes-\(simulated)", held: Set(Kind.allCases))
            let steps = ObservedSteps(rebuild.files)

            try restore(rebuild, simulated: simulated, steps: steps)

            let mode = simulated ? "ExFAT" : "APFS"
            for step in [DurableReplace.Step.staged, .stageSynced, .published, .folderSynced, .observed, .retiredRemoved] {
                XCTAssertEqual(steps.rows.filter { $0.step == step }.count, 4, "\(mode): \(step) once for each of the four files")
            }
            XCTAssertEqual(steps.rows.filter { $0.step == .flushed }.count, 1, "\(mode): one flush for the transaction")
            try assertRestored(rebuild.files, mode)
        }
    }

    /// The database name holds a complete file at every step, the earlier one or the rebuild's, and never
    /// nothing. The journal and the shared-memory file of the rebuild are gone before the earlier database is
    /// back, since a journal that stays beside an older database is replayed into it.
    func testTheDatabaseNameIsNeverEmptyAndTheEarlierDatabaseNeverMeetsTheRebuildsJournal() throws {
        for simulated in [false, true] {
            let rebuild = try seedRebuild("never-empty-\(simulated)", held: [.database, .record])
            let steps = ObservedSteps(rebuild.files)

            try restore(rebuild, simulated: simulated, steps: steps)

            let mode = simulated ? "ExFAT" : "APFS"
            XCTAssertFalse(steps.rows.isEmpty, "\(mode): the restore went through DurableReplace")
            for row in steps.rows {
                XCTAssertTrue(
                    ["rebuilt database", "earlier database"].contains(row.database ?? "nothing"),
                    "\(mode): at \(row.step) the database name held \(row.database ?? "nothing")"
                )
                if row.database == "earlier database" {
                    XCTAssertFalse(row.journal || row.sharedMemory, "\(mode): at \(row.step) the earlier database met the rebuild's journal")
                }
            }
            try assertRestored(rebuild.files, mode, held: [.database, .record])
        }
    }

    /// A restore that stops at any step of any of the four publications keeps a complete file under every
    /// name, leaves no stage or tombstone, keeps the snapshot, and a second restore finishes the job.
    func testARestoreThatStopsAtAnyStepKeepsACompleteFileUnderEveryNameAndCanBeRunAgain() throws {
        for simulated in [false, true] {
            let mode = simulated ? "ExFAT" : "APFS"
            for step in DurableReplace.Step.allCases {
                // The flush comes once for the whole transaction. Every other step comes once for each file.
                for occurrence in 1...(step == .flushed ? 1 : 4) {
                    let label = "\(mode), \(step) \(occurrence)"
                    let rebuild = try seedRebuild("stops-\(simulated)-\(step.rawValue)-\(occurrence)", held: Set(Kind.allCases))
                    let fault = FaultAt(step, occurrence: occurrence)

                    XCTAssertThrowsError(try restore(rebuild, simulated: simulated, fault: fault), label)

                    XCTAssertTrue(fault.fired, "\(label): the fault fired")
                    for kind in Kind.allCases {
                        let text = try read(rebuild.files.url(kind))
                        XCTAssertTrue(
                            ["rebuilt \(kind.rawValue)", "earlier \(kind.rawValue)"].contains(text ?? "nothing"),
                            "\(label): \(kind) held \(text ?? "nothing")"
                        )
                    }
                    XCTAssertEqual(try leftovers(in: rebuild.folder), [], "\(label): no stage or tombstone is left")

                    try restore(rebuild, simulated: simulated)

                    try assertRestored(rebuild.files, label)
                    XCTAssertEqual(try leftovers(in: rebuild.folder), [], "\(label): none after the second restore")
                }
            }
        }
    }

    // MARK: Helpers

    /// The files of one database in a result folder.
    private enum Kind: String, CaseIterable {
        case database, journal, sharedMemory, record
    }

    private struct Files: Sendable {
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

    private struct Rebuild {
        let folder: URL
        let files: Files
        let snapshot: BuildDbDatabaseSnapshot
    }

    private struct Fault: Error {}

    /// A folder that held the `held` files of an earlier build, captured, and then every file written with
    /// other bytes, as a rebuild that stopped leaves it.
    private func seedRebuild(_ label: String, held: Set<Kind>) throws -> Rebuild {
        let folder = try folder(label)
        let files = Files(in: folder)
        for kind in held {
            try write("earlier \(kind.rawValue)", to: files.url(kind))
        }
        let snapshot = try BuildDbDatabaseSnapshot.capture(dbURL: files.database)
        for kind in Kind.allCases {
            try write("rebuilt \(kind.rawValue)", to: files.url(kind))
        }
        return Rebuild(folder: folder, files: files, snapshot: snapshot)
    }

    /// Restores `rebuild` with the system calls of an APFS or a simulated ExFAT volume.
    private func restore(
        _ rebuild: Rebuild,
        simulated: Bool,
        steps: ObservedSteps? = nil,
        fault: FaultAt? = nil
    ) throws {
        var rename = PortableRename.Operations()
        if simulated {
            rename.nativeRename = { sourceParent, source, destinationParent, destination, flags in
                if flags != 0 {
                    errno = ENOTSUP
                    return -1
                }
                return Darwin.renameatx_np(sourceParent, source, destinationParent, destination, flags)
            }
        }
        let operations = DurableReplace.Operations(rename: rename, checkpoint: { step in
            steps?.reached(step)
            try fault?.reached(step)
        })
        try DurableReplace.$overrideOperations.withValue(operations) {
            try rebuild.snapshot.restore()
        }
    }

    /// Captures a folder that held the `held` files of an earlier build, lets a rebuild write every file
    /// with other bytes, restores, and expects the earlier bytes back for each held file and nothing for
    /// each other file.
    private func assertRestore(
        whenTheEarlierBuildHeld held: Set<Kind>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let rebuild = try seedRebuild("restore-\(held.map(\.rawValue).sorted().joined(separator: "-"))", held: held)

        try rebuild.snapshot.restore()

        try assertRestored(rebuild.files, "after a restore", held: held, file: file, line: line)
    }

    private func assertRestored(
        _ files: Files,
        _ label: String,
        held: Set<Kind> = Set(Kind.allCases),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for kind in Kind.allCases {
            XCTAssertEqual(
                try read(files.url(kind)), held.contains(kind) ? "earlier \(kind.rawValue)" : nil,
                "\(label): \(kind)", file: file, line: line
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

    private func leftovers(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.contains(DurableReplace.stageInfix) || $0.contains(PortableRename.swapTombstoneInfix) }
            .sorted()
    }

    /// What the folder held each time the restore reached a step of a publication.
    private final class ObservedSteps: @unchecked Sendable {
        struct Row {
            let step: DurableReplace.Step
            let database: String?
            let journal: Bool
            let sharedMemory: Bool
        }

        private let files: Files
        private let lock = NSLock()
        private var observed: [Row] = []

        init(_ files: Files) {
            self.files = files
        }

        var rows: [Row] {
            lock.withLock { observed }
        }

        func reached(_ step: DurableReplace.Step) {
            let manager = FileManager.default
            let database = manager.contents(atPath: files.database.path).map { String(decoding: $0, as: UTF8.self) }
            let row = Row(
                step: step,
                database: database,
                journal: manager.fileExists(atPath: files.journal.path),
                sharedMemory: manager.fileExists(atPath: files.sharedMemory.path)
            )
            lock.withLock { observed.append(row) }
        }
    }

    /// Fails the n-th time the restore reaches a step.
    private final class FaultAt: @unchecked Sendable {
        private let step: DurableReplace.Step
        private let occurrence: Int
        private let lock = NSLock()
        private var reachedCount = 0
        private var didFire = false

        init(_ step: DurableReplace.Step, occurrence: Int) {
            self.step = step
            self.occurrence = occurrence
        }

        var fired: Bool { lock.withLock { didFire } }

        func reached(_ current: DurableReplace.Step) throws {
            guard current == step else { return }
            let fire = lock.withLock { () -> Bool in
                reachedCount += 1
                guard reachedCount == occurrence, !didFire else { return false }
                didFire = true
                return true
            }
            if fire { throw Fault() }
        }
    }
}
