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
