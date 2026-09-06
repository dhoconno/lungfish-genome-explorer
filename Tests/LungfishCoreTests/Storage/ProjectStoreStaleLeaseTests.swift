import XCTest
@testable import LungfishCore

final class ProjectStoreStaleLeaseTests: XCTestCase {
    private func project() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stale-lease-\(UUID().uuidString)")
        do {
            let store = try ProjectStore(creating: url)
            withExtendedLifetime(store) {}
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectLockManager.lockURL(for: url).path))
        return url
    }

    private func record(for project: URL, user: String? = nil, host: String? = nil, stale: Bool = true) -> ProjectLockRecord {
        let current = ProjectLockRecord.current(projectURL: project, mode: "write", toolName: "fixture", appVersion: "test")
        return ProjectLockRecord(schemaVersion: current.schemaVersion, toolName: current.toolName,
            appVersion: current.appVersion, projectPath: current.projectPath, mode: current.mode,
            user: user ?? current.user, host: host ?? current.host, pid: current.pid,
            processStartTime: stale ? "previous process incarnation" : current.processStartTime,
            cwd: current.cwd, createdAt: current.createdAt)
    }

    func testWritableOpenReclaimsSameUserLocalStaleLease() throws {
        let url = try project()
        let manager = ProjectLockManager()
        let lockURL = ProjectLockManager.lockURL(for: url)
        let stale = record(for: url)
        XCTAssertEqual(manager.status(of: stale), .stale)
        try manager.writeLock(stale, to: lockURL)
        let store = try ProjectStore(opening: url, access: .writable)
        XCTAssertTrue(ProjectStore.ownsWriterLease(at: url))
        XCTAssertNotEqual(try manager.readLock(at: lockURL), stale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectLockManager.replacementLockURL(forLockAt: lockURL).path))
        withExtendedLifetime(store) {}
    }

    func testWritableOpenPreservesActiveUnknownAndOtherUserLocks() throws {
        for kind in ["active", "unknown", "other-user"] {
            let url = try project()
            let manager = ProjectLockManager()
            let lockURL = ProjectLockManager.lockURL(for: url)
            let owner = record(for: url, user: kind == "other-user" ? "another-user" : nil,
                host: kind == "unknown" ? "unrelated.example.invalid" : nil, stale: kind != "active")
            try manager.writeLock(owner, to: lockURL)
            let bytes = try Data(contentsOf: lockURL)
            XCTAssertThrowsError(try ProjectStore(opening: url, access: .writable), kind)
            XCTAssertEqual(try Data(contentsOf: lockURL), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectLockManager.replacementLockURL(forLockAt: lockURL).path))
        }
    }

    func testWritableOpenNeverReplacesOccupiedReplacementGate() throws {
        let url = try project()
        let manager = ProjectLockManager()
        let lockURL = ProjectLockManager.lockURL(for: url)
        let gateURL = ProjectLockManager.replacementLockURL(forLockAt: lockURL)
        let stale = record(for: url)
        try manager.writeLock(stale, to: lockURL)
        // Even a stale gate requires explicit recovery; automatic gate theft races another contender.
        try manager.writeLock(stale, to: gateURL)
        let primaryBytes = try Data(contentsOf: lockURL)
        let gateBytes = try Data(contentsOf: gateURL)
        XCTAssertThrowsError(try ProjectStore(opening: url, access: .writable))
        XCTAssertEqual(try Data(contentsOf: lockURL), primaryBytes)
        XCTAssertEqual(try Data(contentsOf: gateURL), gateBytes)
    }

    func testWritableOpenReclaimsSameMachineStaleLeaseAfterHostnameChange() throws {
        let url = try project()
        let current = ProjectLockRecord.current(projectURL: url, mode: "write", toolName: "fixture", appVersion: "test")
        let machine = try XCTUnwrap(current.machineIdentifier)
        let stale = ProjectLockRecord(schemaVersion: 1, toolName: current.toolName,
            appVersion: current.appVersion, projectPath: current.projectPath, mode: current.mode,
            user: current.user, host: "previous-vpn.example.invalid", pid: current.pid,
            processStartTime: "previous process incarnation", cwd: current.cwd,
            createdAt: current.createdAt, machineIdentifier: machine)
        let manager = ProjectLockManager()
        XCTAssertEqual(manager.status(of: stale), .stale)
        try manager.writeLock(stale, to: ProjectLockManager.lockURL(for: url))
        let store = try ProjectStore(opening: url, access: .writable)
        XCTAssertTrue(ProjectStore.ownsWriterLease(at: url))
        withExtendedLifetime(store) {}
    }
}
