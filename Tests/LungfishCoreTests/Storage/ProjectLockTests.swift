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

    // MARK: - R3-R3ML-2: ProjectProcessInspector must not fork /bin/ps

    func testProcessStartTimeReturnsNonEmptyStringForCurrentProcess() {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)

        let startTime = ProjectProcessInspector.processStartTime(for: pid)

        XCTAssertNotNil(startTime)
        XCTAssertFalse(startTime?.isEmpty ?? true)
    }

    func testProcessStartTimeIsStableAcrossRepeatedCallsForSameProcess() {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)

        let first = ProjectProcessInspector.processStartTime(for: pid)
        let second = ProjectProcessInspector.processStartTime(for: pid)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    func testProcessStartTimeReturnsNilForNonexistentPID() {
        // A PID astronomically unlikely to be assigned to a live process.
        let unusedPID = 999_999

        let startTime = ProjectProcessInspector.processStartTime(for: unusedPID)

        XCTAssertNil(startTime)
    }

    /// R3-R3ML-2 regression guard: the previous implementation forked `/bin/ps` and
    /// waited on it synchronously (Process().run() + waitUntilExit()), which is the
    /// "main-thread sync subprocess spawn" pattern flagged in the campaign. A native
    /// (no-subprocess) implementation should resolve near-instantly; this bounds
    /// 200 repeated calls well under what 200 sequential `/bin/ps` forks would cost
    /// (each fork+exec+wait is typically several milliseconds; 200 of them would push
    /// this well past a second on a loaded CI machine).
    func testProcessStartTimeResolvesQuicklyWithoutSpawningASubprocess() {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)

        let start = Date()
        for _ in 0..<200 {
            _ = ProjectProcessInspector.processStartTime(for: pid)
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0, "200 calls took \(elapsed)s -- suggests a subprocess is still being spawned per call")
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

    func testReadLockResultReportsCorruptedLockJSON() throws {
        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let lockURL = ProjectLockManager.lockURL(for: projectURL)
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{not-json".write(to: lockURL, atomically: true, encoding: .utf8)

        let result = try ProjectLockManager().readLockResult(at: lockURL)

        guard case .corrupted(let corruption) = result else {
            return XCTFail("Expected corrupted lock result, got \(result)")
        }
        XCTAssertEqual(corruption.lockURL, lockURL)
        XCTAssertFalse(corruption.reason.isEmpty)
        XCTAssertTrue(corruption.localizedDescription.contains("Project lock file is corrupted"))
    }

    func testReadLockThrowsTypedErrorForCorruptedLockJSON() throws {
        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let lockURL = ProjectLockManager.lockURL(for: projectURL)
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{not-json".write(to: lockURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ProjectLockManager().readLock(at: lockURL)) { error in
            guard let corruption = error as? ProjectLockCorruption else {
                return XCTFail("Expected ProjectLockCorruption, got \(error)")
            }
            XCTAssertEqual(corruption.lockURL, lockURL)
        }
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
