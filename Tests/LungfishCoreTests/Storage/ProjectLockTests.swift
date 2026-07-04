import Foundation
@testable import LungfishCore
import XCTest

final class ProjectLockTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testAcquireLockCreatesRecordWhenLockFileDoesNotExist() throws {
        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let lockURL = ProjectLockManager.lockURL(for: projectURL)
        let record = makeRecord(projectURL: projectURL, mode: "exclusive")

        let acquired = try ProjectLockManager().acquireLock(record, to: lockURL)

        XCTAssertTrue(acquired)
        XCTAssertEqual(try ProjectLockManager().readLock(at: lockURL), record)
    }

    func testAcquireLockDoesNotOverwriteExistingRecord() throws {
        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let lockURL = ProjectLockManager.lockURL(for: projectURL)
        let originalRecord = makeRecord(projectURL: projectURL, mode: "original")
        let replacementRecord = makeRecord(projectURL: projectURL, mode: "replacement")
        try ProjectLockManager().writeLock(originalRecord, to: lockURL)
        let originalData = try Data(contentsOf: lockURL)

        let acquired = try ProjectLockManager().acquireLock(replacementRecord, to: lockURL)

        XCTAssertFalse(acquired)
        XCTAssertEqual(try Data(contentsOf: lockURL), originalData)
        XCTAssertEqual(try ProjectLockManager().readLock(at: lockURL), originalRecord)
    }

    func testConcurrentAcquireLockAllowsOnlyOneWinner() throws {
        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let lockURL = ProjectLockManager.lockURL(for: projectURL)
        let records = (0..<20).map { index in
            makeRecord(projectURL: projectURL, mode: "attempt-\(index)")
        }
        let collector = ConcurrentAcquireCollector()
        let group = DispatchGroup()

        for record in records {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    if try ProjectLockManager().acquireLock(record, to: lockURL) {
                        collector.recordWin(record.mode)
                    }
                } catch {
                    collector.recordError(error)
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(collector.errors.isEmpty, "Unexpected acquisition errors: \(collector.errors)")
        XCTAssertEqual(collector.winningModes.count, 1)
        XCTAssertEqual(try ProjectLockManager().readLock(at: lockURL)?.mode, collector.winningModes.first)
    }

    private func makeRecord(projectURL: URL, mode: String) -> ProjectLockRecord {
        ProjectLockRecord(
            schemaVersion: 1,
            toolName: "lungfish project lock",
            appVersion: "test",
            projectPath: projectURL.standardizedFileURL.path,
            mode: mode,
            user: "test-user",
            host: ProcessInfo.processInfo.hostName,
            pid: 1234,
            processStartTime: "2026-07-04T00:00:00Z",
            cwd: tempDir.path,
            createdAt: "2026-07-04T00:00:00Z"
        )
    }
}

private final class ConcurrentAcquireCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var wins: [String] = []
    private var failures: [String] = []

    var winningModes: [String] {
        lock.withLock { wins }
    }

    var errors: [String] {
        lock.withLock { failures }
    }

    func recordWin(_ mode: String) {
        lock.withLock {
            wins.append(mode)
        }
    }

    func recordError(_ error: Error) {
        lock.withLock {
            failures.append(error.localizedDescription)
        }
    }
}
