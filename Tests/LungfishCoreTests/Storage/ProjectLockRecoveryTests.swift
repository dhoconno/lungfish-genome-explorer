import CryptoKit
import Foundation
import XCTest
@testable import LungfishCore

final class ProjectLockRecoveryTests: XCTestCase {
    private var projectURL: URL!
    private var lockURL: URL { ProjectLockManager.lockURL(for: projectURL) }

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectLockRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: projectURL)
    }

    func testExplicitUnknownLegacyRecoveryArchivesExactBytesAndMetadata() throws {
        try writeUnknown()
        let bytes = try Data(contentsOf: lockURL)
        let snapshot = try ProjectLockRecoverySnapshot.capture(projectURL: projectURL)
        let result = try XCTUnwrap(ProjectLockRecovery.recover(snapshot: snapshot, reason: "User confirmed old VPN hostname"))
        XCTAssertEqual(try Data(contentsOf: result.archiveURL), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.recoveryRecordURL)) as? [String: Any])
        XCTAssertEqual(metadata["reason"] as? String, "User confirmed old VPN hostname")
        XCTAssertEqual(metadata["archivePath"] as? String, result.archiveURL.path)
        XCTAssertEqual(metadata["sha256"] as? String, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertNotNil(metadata["timestamp"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectLockManager.replacementLockURL(forLockAt: lockURL).path))
    }

    func testCorruptLockCanBeExplicitlyArchived() throws {
        let bytes = Data("not JSON\n".utf8)
        try bytes.write(to: lockURL)
        let snapshot = try ProjectLockRecoverySnapshot.capture(projectURL: projectURL)
        guard case .corrupted = snapshot.readResult else { return XCTFail("Expected corrupt lock") }
        let result = try XCTUnwrap(ProjectLockRecovery.recover(snapshot: snapshot, reason: "User confirmed corrupt lock"))
        XCTAssertEqual(try Data(contentsOf: result.archiveURL), bytes)
    }

    func testChangedBytesRefuseRecoveryEvenWhenDecodedRecordIsEqual() throws {
        try writeUnknown()
        let snapshot = try ProjectLockRecoverySnapshot.capture(projectURL: projectURL)
        var replacement = try Data(contentsOf: lockURL)
        replacement.append(Data("\n".utf8))
        try replacement.write(to: lockURL)
        XCTAssertThrowsError(try ProjectLockRecovery.recover(snapshot: snapshot, reason: "Confirm"))
        XCTAssertEqual(try Data(contentsOf: lockURL), replacement)
    }

    func testActiveLocalLockAlwaysRefusesRecovery() throws {
        try ProjectLockManager().writeLock(.current(projectURL: projectURL, mode: "write", toolName: "test", appVersion: "test"), to: lockURL)
        let bytes = try Data(contentsOf: lockURL)
        let snapshot = try ProjectLockRecoverySnapshot.capture(projectURL: projectURL)
        XCTAssertThrowsError(try ProjectLockRecovery.recover(snapshot: snapshot, reason: "Confirm"))
        XCTAssertEqual(try Data(contentsOf: lockURL), bytes)
    }

    func testOccupiedGateIsPreserved() throws {
        try writeUnknown()
        let snapshot = try ProjectLockRecoverySnapshot.capture(projectURL: projectURL)
        let gate = ProjectLockManager.replacementLockURL(forLockAt: lockURL)
        let bytes = Data("existing recovery gate".utf8)
        try bytes.write(to: gate)
        XCTAssertThrowsError(try ProjectLockRecovery.recover(snapshot: snapshot, reason: "Confirm"))
        XCTAssertEqual(try Data(contentsOf: gate), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testMissingLockIsBenignButNewLockAfterMissingSnapshotIsPreserved() throws {
        let missing = try ProjectLockRecoverySnapshot.capture(projectURL: projectURL)
        XCTAssertNil(try ProjectLockRecovery.recover(snapshot: missing, reason: "Confirm"))
        try writeUnknown()
        let bytes = try Data(contentsOf: lockURL)
        XCTAssertThrowsError(try ProjectLockRecovery.recover(snapshot: missing, reason: "Confirm"))
        XCTAssertEqual(try Data(contentsOf: lockURL), bytes)
        let existing = try ProjectLockRecoverySnapshot.capture(projectURL: projectURL)
        try FileManager.default.removeItem(at: lockURL)
        XCTAssertNil(try ProjectLockRecovery.recover(snapshot: existing, reason: "Confirm"))
    }

    private func writeUnknown() throws {
        let current = ProjectLockRecord.current(projectURL: projectURL, mode: "write", toolName: "test", appVersion: "test")
        let legacy = ProjectLockRecord(schemaVersion: 1, toolName: current.toolName, appVersion: current.appVersion,
            projectPath: current.projectPath, mode: current.mode, user: current.user, host: "previous-vpn.invalid",
            pid: current.pid, processStartTime: current.processStartTime, cwd: current.cwd, createdAt: current.createdAt)
        try ProjectLockManager().writeLock(legacy, to: lockURL)
    }
}
