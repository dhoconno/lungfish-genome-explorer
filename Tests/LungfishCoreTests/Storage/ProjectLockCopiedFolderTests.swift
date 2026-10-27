import Darwin
import XCTest
@testable import LungfishCore

/// Finder copies `.lungfish/project.lock` with a project, and the copied record names
/// the original folder. That lock does not hold the copy, so the copy opens with write
/// access and its lock is rewritten to name the copy. A lock that names the folder being
/// opened and a live session still refuses a writer (3.0 lane PROJECT-LOCK, walk WF-2).
final class ProjectLockCopiedFolderTests: XCTestCase {
    private var root: URL!
    private var original: URL { root.appendingPathComponent("P.lungfish", isDirectory: true) }
    private var copy: URL { root.appendingPathComponent("P.lungfish copy", isDirectory: true) }
    private var moved: URL { root.appendingPathComponent("Moved.lungfish", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectLockCopiedFolderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do { let created = try ProjectStore(creating: original); withExtendedLifetime(created) {} }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Rows of the case table that change

    func testCopyOfAnOpenProjectOpensWritable() throws {
        let store = try ProjectStore(opening: original, access: .writable)
        let originalLock = try Data(contentsOf: ProjectLockManager.lockURL(for: original))
        try FileManager.default.copyItem(at: original, to: copy)

        let copied = try ProjectStore(opening: copy, access: .writable)

        XCTAssertEqual(try ProjectLockManager().readLock(forProjectAt: copy)?.projectPath, copy.standardizedFileURL.path,
            "The copy's lock is rewritten to name the copy")
        XCTAssertEqual(try Data(contentsOf: ProjectLockManager.lockURL(for: original)), originalLock,
            "The original's lock is never touched")
        XCTAssertTrue(ProjectStore.ownsWriterLease(at: original))
        XCTAssertTrue(ProjectStore.ownsWriterLease(at: copy))
        withExtendedLifetime((store, copied)) {}
    }

    func testCopyOpensWritableAfterTheOriginalCloses() throws {
        try copyWhileTheOriginalIsOpenThenCloseIt()

        let copied = try ProjectStore(opening: copy, access: .writable)

        XCTAssertEqual(try ProjectLockManager().readLock(forProjectAt: copy)?.projectPath, copy.standardizedFileURL.path)
        withExtendedLifetime(copied) {}
    }

    /// The copied lock names this process, the original folder is gone and no lease
    /// in this process holds the record, so nothing holds the copy.
    func testCopyOpensWritableAfterTheOriginalClosesAndIsDeleted() throws {
        try copyWhileTheOriginalIsOpenThenCloseIt()
        try FileManager.default.removeItem(at: original)

        let copied = try ProjectStore(opening: copy, access: .writable)

        XCTAssertEqual(try ProjectLockManager().readLock(forProjectAt: copy)?.projectPath, copy.standardizedFileURL.path)
        withExtendedLifetime(copied) {}
    }

    // MARK: - Rows of the case table that stay

    func testSameFolderLockOfALiveSessionStillRefusesAWriter() throws {
        let record = try liveSessionRecord(projectPath: original.standardizedFileURL.path)
        try ProjectLockManager().writeLock(record, to: ProjectLockManager.lockURL(for: original))

        XCTAssertThrowsError(try ProjectStore(opening: original, access: .writable))
        XCTAssertEqual(try ProjectLockManager().readLock(forProjectAt: original), record)
    }

    func testProjectMovedWhileOpenStillRefusesASecondWriter() throws {
        let store = try ProjectStore(opening: original, access: .writable)
        try FileManager.default.moveItem(at: original, to: moved)
        let lease = try ProjectLockManager().readLock(forProjectAt: moved)

        XCTAssertThrowsError(try ProjectStore(opening: moved, access: .writable))
        XCTAssertEqual(try ProjectLockManager().readLock(forProjectAt: moved), lease)
        withExtendedLifetime(store) {}
    }

    func testProjectMovedWhileClosedWithADeadWritersLockOpensWritable() throws {
        let dead = try identity(of: liveSessionRecord(projectPath: original.standardizedFileURL.path), pid: 999_999)
        try ProjectLockManager().writeLock(dead, to: ProjectLockManager.lockURL(for: original))
        try FileManager.default.moveItem(at: original, to: moved)

        let store = try ProjectStore(opening: moved, access: .writable)

        XCTAssertEqual(try ProjectLockManager().readLock(forProjectAt: moved)?.projectPath, moved.standardizedFileURL.path)
        withExtendedLifetime(store) {}
    }

    /// The Recover dialog keeps asking for a copy whose original is gone while the
    /// process its lock names still runs.
    func testCopyWhoseOriginalWasDeletedStillRefusesWhileItsSessionLives() throws {
        try FileManager.default.copyItem(at: original, to: copy)
        try FileManager.default.removeItem(at: original)
        let record = try liveSessionRecord(projectPath: original.standardizedFileURL.path)
        try ProjectLockManager().writeLock(record, to: ProjectLockManager.lockURL(for: copy))

        XCTAssertThrowsError(try ProjectStore(opening: copy, access: .writable))
        XCTAssertEqual(try ProjectLockManager().readLock(forProjectAt: copy), record)
    }

    // MARK: - The rule, status(of:forProjectAt:)

    func testLockCopiedWithItsFolderIsStaleWhileItsWriterLives() throws {
        let manager = ProjectLockManager()
        let record = ProjectLockRecord.current(projectURL: original, mode: "exclusive", toolName: "test", appVersion: "test")
        try manager.writeLock(record, to: ProjectLockManager.lockURL(for: original))
        try FileManager.default.copyItem(at: original, to: copy)
        let copied = try XCTUnwrap(manager.readLock(forProjectAt: copy))

        XCTAssertEqual(copied, record)
        XCTAssertEqual(manager.status(of: copied, forProjectAt: copy), .stale)
        XCTAssertEqual(manager.status(of: record, forProjectAt: original), .active)
        XCTAssertTrue(manager.namesAnotherFolder(copied, forProjectAt: copy))
        XCTAssertFalse(manager.namesAnotherFolder(record, forProjectAt: original))
    }

    func testCopiedLockOfAnotherLiveProcessIsRemovableWithoutForceOnlyFromTheCopy() throws {
        let manager = ProjectLockManager()
        try FileManager.default.copyItem(at: original, to: copy)
        let record = try liveSessionRecord(projectPath: original.standardizedFileURL.path)

        XCTAssertEqual(manager.status(of: record, forProjectAt: copy), .stale)
        XCTAssertTrue(manager.canRemoveWithoutForce(record, forProjectAt: copy))
        XCTAssertEqual(manager.status(of: record, forProjectAt: original), .active)
        XCTAssertFalse(manager.canRemoveWithoutForce(record, forProjectAt: original))
    }

    func testSameFolderLockOfALiveProcessStaysActive() throws {
        let record = try liveSessionRecord(projectPath: original.standardizedFileURL.path)

        XCTAssertEqual(ProjectLockManager().status(of: record, forProjectAt: original), .active)
    }

    func testRemoteLockNamingAnotherPathStaysUnknown() throws {
        try FileManager.default.copyItem(at: original, to: copy)
        let local = try liveSessionRecord(projectPath: original.standardizedFileURL.path)
        let remote = ProjectLockRecord(schemaVersion: 1, toolName: local.toolName, appVersion: local.appVersion,
            projectPath: local.projectPath, mode: local.mode, user: local.user, host: "another-mac.invalid",
            pid: local.pid, processStartTime: local.processStartTime, cwd: local.cwd, createdAt: local.createdAt,
            machineIdentifier: "another-machine")

        XCTAssertEqual(ProjectLockManager().status(of: remote, forProjectAt: copy), .unknown)
        XCTAssertFalse(ProjectLockManager().namesAnotherFolder(remote, forProjectAt: copy))
    }

    func testSymlinkAliasOfTheSameFolderIsNotACopy() throws {
        let alias = root.appendingPathComponent("Alias.lungfish", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let record = try liveSessionRecord(projectPath: alias.path)

        XCTAssertFalse(ProjectLockManager().namesAnotherFolder(record, forProjectAt: original))
        XCTAssertEqual(ProjectLockManager().status(of: record, forProjectAt: original), .active)
        if original.path.hasPrefix("/var/") {
            let firmPath = try liveSessionRecord(projectPath: "/private" + original.path)
            XCTAssertFalse(ProjectLockManager().namesAnotherFolder(firmPath, forProjectAt: original),
                "A path through /private names the same temporary folder")
        }
    }

    /// A lease record of this process is held only while a lease here holds it.
    func testLeaseRecordOfThisProcessIsStaleOnceItsLeaseEnds() throws {
        let manager = ProjectLockManager()
        let lease: ProjectLockRecord
        do {
            let store = try ProjectStore(opening: original, access: .writable)
            lease = try XCTUnwrap(manager.readLock(forProjectAt: original))
            XCTAssertTrue(ProjectStore.hasLiveWriterLease(holding: lease))
            XCTAssertEqual(manager.status(of: lease, forProjectAt: original), .active)
            withExtendedLifetime(store) {}
        }
        XCTAssertFalse(ProjectStore.hasLiveWriterLease(holding: lease))
        XCTAssertEqual(manager.status(of: lease, forProjectAt: original), .stale)
    }

    /// Only a writer lease's own record is judged by the leases here. A lock this
    /// process took another way, as `lungfish project lock` does, holds while it lives.
    func testOtherLockOfThisProcessStaysActiveWithoutALease() throws {
        let record = ProjectLockRecord.current(projectURL: original, mode: "write", toolName: "lungfish project lock",
            appVersion: "test")

        XCTAssertFalse(ProjectStore.hasLiveWriterLease(holding: record))
        XCTAssertEqual(ProjectLockManager().status(of: record, forProjectAt: original), .active)
    }

    // MARK: - The registry of lease records

    /// Two leases that hold equal records count twice, so ending one keeps the record held.
    func testEqualLeaseRecordsAreHeldUntilTheLastLeaseEnds() throws {
        let record = ProjectLockRecord.current(projectURL: copy, mode: "write",
            toolName: ProjectLockManager.writerLeaseToolName, appVersion: "test")
        let synchronization = ProjectStoreSynchronization()   // the folder does not exist, so no lock file is touched
        func lease() -> ProjectStoreWriterLease {
            ProjectWriterLeaseRecords.register(ProjectStoreWriterLease(lockURL: ProjectLockManager.lockURL(for: copy),
                projectURL: copy, record: record, synchronization: synchronization))
        }
        var first: ProjectStoreWriterLease? = lease()
        var second: ProjectStoreWriterLease? = lease()
        XCTAssertTrue(ProjectStore.hasLiveWriterLease(holding: record))
        first = nil
        XCTAssertTrue(ProjectStore.hasLiveWriterLease(holding: record), "The second lease still holds an equal record")
        second = nil
        XCTAssertFalse(ProjectStore.hasLiveWriterLease(holding: record))
        _ = (first, second)
    }

    // MARK: - Closing either folder leaves the other folder's lock in place

    /// The copy's rewritten lock names the copy, so closing the original removes only the original's lock.
    func testClosingTheOriginalLeavesTheCopysLockInPlace() throws {
        let copied: ProjectStore
        do {
            let store = try ProjectStore(opening: original, access: .writable)
            try FileManager.default.copyItem(at: original, to: copy)
            copied = try ProjectStore(opening: copy, access: .writable)
            withExtendedLifetime(store) {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectLockManager.lockURL(for: original).path),
            "Closing the original removes its own lock")
        XCTAssertEqual(try ProjectLockManager().readLock(forProjectAt: copy)?.projectPath, copy.standardizedFileURL.path)
        XCTAssertTrue(ProjectStore.ownsWriterLease(at: copy))
        withExtendedLifetime(copied) {}
    }

    /// Closing the copy removes only the copy's lock and leaves the original's bytes as they were.
    func testClosingTheCopyLeavesTheOriginalsLockInPlace() throws {
        let store = try ProjectStore(opening: original, access: .writable)
        let originalLock = try Data(contentsOf: ProjectLockManager.lockURL(for: original))
        try FileManager.default.copyItem(at: original, to: copy)
        do { let copied = try ProjectStore(opening: copy, access: .writable); withExtendedLifetime(copied) {} }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectLockManager.lockURL(for: copy).path),
            "Closing the copy removes its own lock")
        XCTAssertEqual(try Data(contentsOf: ProjectLockManager.lockURL(for: original)), originalLock)
        XCTAssertTrue(ProjectStore.ownsWriterLease(at: original))
        withExtendedLifetime(store) {}
    }

    // MARK: - Helpers

    private func copyWhileTheOriginalIsOpenThenCloseIt() throws {
        do {
            let store = try ProjectStore(opening: original, access: .writable)
            try FileManager.default.copyItem(at: original, to: copy)
            withExtendedLifetime(store) {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectLockManager.lockURL(for: original).path),
            "Closing the original removes its own lock")
        XCTAssertNotNil(try ProjectLockManager().readLock(forProjectAt: copy), "The copy keeps the copied lock")
    }

    /// A writer lock of another live process of this user: the test runner that
    /// launched this test process, which lives as long as the test does.
    private func liveSessionRecord(projectPath: String) throws -> ProjectLockRecord {
        let pid = Int(getppid())
        guard pid > 1, kill(pid_t(pid), 0) == 0 else {
            throw XCTSkip("The parent process is not a live process of this user.")
        }
        return ProjectLockRecord(schemaVersion: 1, toolName: "Lungfish ProjectStore", appVersion: "test",
            projectPath: projectPath, mode: "write", user: ProjectLockMetadata.currentUser,
            host: ProcessInfo.processInfo.hostName, pid: pid,
            processStartTime: try XCTUnwrap(ProjectProcessInspector.processStartTime(for: pid)),
            cwd: "/", createdAt: ProjectLockMetadata.nowString(), machineIdentifier: ProjectLockMetadata.machineIdentifier)
    }

    private func identity(of record: ProjectLockRecord, pid: Int) -> ProjectLockRecord {
        ProjectLockRecord(schemaVersion: record.schemaVersion, toolName: record.toolName, appVersion: record.appVersion,
            projectPath: record.projectPath, mode: record.mode, user: record.user, host: record.host, pid: pid,
            processStartTime: record.processStartTime, cwd: record.cwd, createdAt: record.createdAt,
            machineIdentifier: record.machineIdentifier)
    }
}
