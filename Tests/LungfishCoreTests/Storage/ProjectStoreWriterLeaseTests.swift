import XCTest
@testable import LungfishCore

/// A writable store's lease removes the lock it wrote where the project folder
/// is when the lease ends, so a folder moved while open reopens writable (2.11 S60).
final class ProjectStoreWriterLeaseTests: XCTestCase {
    func testReleasedLeaseRemovesItsLockWhereTheMovedProjectNowIs() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("lease-move-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        try assertReleaseFollowsMove(in: parent)
    }

    func testReleasedLeaseRemovesItsLockAfterAMoveOnExFAT() throws {
        let parent = try exfatParent()
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        try assertReleaseFollowsMove(in: parent)
    }

    func testReleasedLeaseKeepsAnotherWritersLockAfterTheProjectMoves() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("lease-move-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let original = parent.appendingPathComponent("original.lungfish", isDirectory: true)
        let moved = parent.appendingPathComponent("moved.lungfish", isDirectory: true)
        let manager = ProjectLockManager()
        do { let created = try ProjectStore(creating: original); withExtendedLifetime(created) {} }
        var other: ProjectLockRecord?
        do {
            let store = try ProjectStore(opening: original, access: .writable, deferCleanup: true)
            try FileManager.default.moveItem(at: original, to: moved)
            let lease = try XCTUnwrap(manager.readLock(forProjectAt: moved))
            let replacement = ProjectLockRecord(schemaVersion: lease.schemaVersion, toolName: "another writer",
                appVersion: lease.appVersion, projectPath: lease.projectPath, mode: lease.mode, user: lease.user,
                host: lease.host, pid: lease.pid, processStartTime: lease.processStartTime, cwd: lease.cwd,
                createdAt: lease.createdAt, machineIdentifier: lease.machineIdentifier)
            try manager.writeLock(replacement, to: ProjectLockManager.lockURL(for: moved))
            other = replacement
            withExtendedLifetime(store) {}
        }
        ProjectStore.flushDeferredCleanup()
        XCTAssertNotNil(other)
        XCTAssertEqual(try manager.readLock(forProjectAt: moved), other,
            "A released lease keeps a lock it did not write, wherever the project folder now is")
    }

    private func assertReleaseFollowsMove(in parent: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let original = parent.appendingPathComponent("original.lungfish", isDirectory: true)
        let moved = parent.appendingPathComponent("moved.lungfish", isDirectory: true)
        do { let created = try ProjectStore(creating: original); withExtendedLifetime(created) {} }
        do {
            let store = try ProjectStore(opening: original, access: .writable, deferCleanup: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: ProjectLockManager.lockURL(for: original).path),
                file: file, line: line)
            try FileManager.default.moveItem(at: original, to: moved)
            withExtendedLifetime(store) {}
        }
        ProjectStore.flushDeferredCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectLockManager.lockURL(for: moved).path),
            "A released lease removes its own lock where the project folder now is", file: file, line: line)
        let reopened = try ProjectStore(opening: moved, access: .writable)
        XCTAssertTrue(ProjectStore.ownsWriterLease(at: moved), file: file, line: line)
        withExtendedLifetime(reopened) {}
    }

    /// A new `lease-move-<UUID>` folder on the ExFAT volume that
    /// `LUNGFISH_EXFAT_TEST_ROOT` names (`scripts/testing/exfat-tests.sh`).
    private func exfatParent() throws -> URL {
        guard let volume = ProcessInfo.processInfo.environment["LUNGFISH_EXFAT_TEST_ROOT"], !volume.isEmpty else {
            throw XCTSkip("Set LUNGFISH_EXFAT_TEST_ROOT to an ExFAT volume root to run this test.")
        }
        var information = statfs()
        guard statfs(volume, &information) == 0 else {
            throw XCTSkip("LUNGFISH_EXFAT_TEST_ROOT does not name a mounted volume.")
        }
        let typeName = withUnsafeBytes(of: information.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard typeName == "exfat" else {
            throw XCTSkip("LUNGFISH_EXFAT_TEST_ROOT is \(typeName), not exfat.")
        }
        let parent = URL(fileURLWithPath: volume, isDirectory: true)
            .appendingPathComponent("lease-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent
    }
}
