// ProjectTempCleanupTests.swift — Tests for project-aware temp file cleanup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import LungfishWorkflow
import XCTest
@testable import LungfishApp
@testable import LungfishIO

final class ProjectTempCleanupTests: XCTestCase {

    private var tempDir: URL!
    private var projectURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectTempCleanupTests-\(UUID().uuidString)")
        projectURL = tempDir.appendingPathComponent("test.lungfish")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    // MARK: - Cleanup requires terminal ownership authority

    func testCleanAllPreservesActiveAndUnmarkedWork() throws {
        // Create temp dirs with files inside the project .tmp/
        let dir1 = try makeOwnedTemp(prefix: "classify-")
        try Data(repeating: 0xAA, count: 512).write(to: dir1.appendingPathComponent("out.txt"))
        let dir2 = try makeOwnedTemp(prefix: "map-")
        try Data(repeating: 0xBB, count: 256).write(to: dir2.appendingPathComponent("out.bam"))

        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpRoot.path))

        // Act
        try ProjectTempDirectory.cleanAll(in: projectURL)

        // Assert
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir2.path))
    }

    func testCleanAllIsIdempotentOnEmptyProject() throws {
        // No .tmp/ directory exists
        XCTAssertNoThrow(try ProjectTempDirectory.cleanAll(in: projectURL))
        // Call again — still no error
        XCTAssertNoThrow(try ProjectTempDirectory.cleanAll(in: projectURL))
    }

    // MARK: - diskUsage

    func testDiskUsageReturnsCorrectByteCount() throws {
        let dir = try makeOwnedTemp(prefix: "usage-")
        let payload = Data(repeating: 0xCC, count: 2048)
        try payload.write(to: dir.appendingPathComponent("payload.bin"))

        let usage = ProjectTempDirectory.diskUsage(in: projectURL)
        XCTAssertGreaterThanOrEqual(usage, 2048,
                                    "Disk usage should be at least the size of the written payload")
    }

    func testDiskUsageReturnsZeroWithNoTmpDir() {
        let usage = ProjectTempDirectory.diskUsage(in: projectURL)
        XCTAssertEqual(usage, 0)
    }

    // MARK: - cleanStale

    func testCleanStalePreservesOldActiveDirectory() throws {
        let recentDir = try makeOwnedTemp(prefix: "recent-")
        let staleDir = try makeOwnedTemp(prefix: "stale-")

        // Backdate staleDir to 25 hours ago
        let twentyFiveHoursAgo = Date(timeIntervalSinceNow: -25 * 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: twentyFiveHoursAgo],
            ofItemAtPath: staleDir.path
        )

        // Clean entries older than 24 hours
        try ProjectTempDirectory.cleanStale(in: projectURL, olderThan: 24 * 3600)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staleDir.path),
            "Age alone does not prove an active owner is dead"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentDir.path),
                      "Recent directory should still exist")
    }

    func testCleanupRemovesTerminalAttestedDirectory() throws {
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectURL)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let terminal = try OwnedWorkDirectoryMarkerStore.createDirectory(
            OwnedWorkDirectoryCreationRequest(
                projectURL: projectURL,
                parentDirectoryURL: tmpRoot,
                prefix: "terminal-",
                runID: UUID(),
                processIdentity: .init(
                    processIdentifier: 999,
                    processStartTime: 1,
                    bootSessionID: "test-boot"
                ),
                state: .completed,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: "test",
                toolVersion: "1"
            )
        )
        try Data(repeating: 0xAA, count: 64).write(
            to: terminal.appendingPathComponent("payload.bin")
        )

        try ProjectTempDirectory.cleanAll(in: projectURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: terminal.path))
    }

    func testCleanStaleKeepsAllRecentDirectories() throws {
        let dir1 = try makeOwnedTemp(prefix: "a-")
        let dir2 = try makeOwnedTemp(prefix: "b-")

        // Both are brand new — nothing should be removed
        try ProjectTempDirectory.cleanStale(in: projectURL, olderThan: 24 * 3600)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir2.path))
    }

    func testCleanStaleNoOpWhenTmpMissing() throws {
        // No .tmp/ exists — should not throw
        XCTAssertNoThrow(
            try ProjectTempDirectory.cleanStale(in: projectURL, olderThan: 24 * 3600)
        )
    }

    func testDebugEscapedTempScanTimerIsRetainedAndInvalidated() {
        let source = combinedAppDelegateSource()

        XCTAssertTrue(source.contains("debugTempEscapeScanTimer"))
        XCTAssertTrue(source.contains("debugTempEscapeScanTimer?.invalidate()"))
        XCTAssertTrue(source.contains("debugTempEscapeScanTimer = Timer.scheduledTimer"))
    }

    func testProjectOpenDoesNotCallCleanupOrScan() {
        let source = combinedAppDelegateSource()
        let openProject = try? XCTUnwrap(
            source.range(of: "internal func openProject(")
        ).lowerBound
        let nextMethod = openProject.flatMap {
            source.range(
                of: "\n    internal func updateProjectWindowTitle",
                range: $0..<source.endIndex
            )?.lowerBound
        }
        let body: String
        if let openProject, let nextMethod {
            body = String(source[openProject..<nextMethod])
        } else {
            body = ""
        }

        XCTAssertFalse(body.contains("cleanAll"))
        XCTAssertFalse(body.contains("cleanStale"))
        XCTAssertFalse(body.contains("ProjectStorageScanner"))
        XCTAssertFalse(body.contains("cleanProjectTempOnOpen"))
        XCTAssertTrue(body.contains("startProjectTempCleanupTimer"))
    }

    func testPeriodicCleanupUsesAutomaticServiceOffMainActor() {
        let source = combinedAppDelegateSource()

        XCTAssertTrue(
            source.contains("ProjectStorageAutomaticCleanupService")
        )
        XCTAssertTrue(source.contains("Task.detached(priority: .utility)"))
        XCTAssertFalse(
            source.contains(
                "ProjectTempDirectory.cleanStale(in: projectURL"
            )
        )
        XCTAssertFalse(
            source.contains("ProjectTempDirectory.cleanAll(in:")
        )
        XCTAssertTrue(source.contains("trigger: .userRequested"))
        let clearStart = source.range(
            of: "@objc func clearProjectTempFiles"
        )?.lowerBound
        let clearEnd = clearStart.flatMap {
            source.range(
                of: "\n    /// Formats a byte count",
                range: $0..<source.endIndex
            )?.lowerBound
        }
        if let clearStart, let clearEnd {
            let clearBody = source[clearStart..<clearEnd]
            XCTAssertFalse(clearBody.contains("diskUsage"))
        } else {
            XCTFail("Could not locate Clear Temporary Files implementation")
        }
    }

    @MainActor
    func testPeriodicCleanupRunnerExecutesOffMainThread() async {
        let delegate = AppDelegate()
        let observedMainThread = ThreadObservation()
        delegate.projectStorageAutomaticCleanupRunner = { projectURL in
            observedMainThread.record(Darwin.pthread_main_np() != 0)
            return .init(
                state: .noEligibleEntries,
                scannedEntryCount: 0,
                selectedEntryCount: 0,
                warnings: [],
                summaryURL: nil,
                provenanceURL: nil
            )
        }

        delegate.testingRunAutomaticProjectStorageCleanup(projectURL)
        await delegate.testingWaitForAutomaticProjectStorageCleanup(
            projectURL
        )

        XCTAssertEqual(observedMainThread.value, false)
    }

    @MainActor
    func testSupersededCleanupCannotClearNewTrackedTask() async {
        let delegate = AppDelegate()
        let sequence = SequencedCleanupRunner()
        let staleCompletionProcessed = expectation(
            description: "stale completion processed"
        )
        delegate.projectStorageAutomaticCleanupRunner = { _ in
            await sequence.run()
        }
        delegate.projectStorageAutomaticCleanupDidProcessCompletion = {
            _, isCurrent in
            if !isCurrent {
                staleCompletionProcessed.fulfill()
            }
        }

        delegate.testingRunAutomaticProjectStorageCleanup(projectURL)
        await sequence.waitForCallCount(1)
        delegate.testingRunAutomaticProjectStorageCleanup(projectURL)
        await sequence.waitForCallCount(2)

        await sequence.resume(call: 0)
        await fulfillment(
            of: [staleCompletionProcessed],
            timeout: 10
        )
        XCTAssertTrue(
            delegate.testingHasTrackedAutomaticProjectStorageCleanup(
                projectURL
            ),
            "A stale completion must not clear the newer tracked task"
        )

        await sequence.resume(call: 1)
        await delegate.testingWaitForAutomaticProjectStorageCleanup(
            projectURL
        )
        XCTAssertFalse(
            delegate.testingHasTrackedAutomaticProjectStorageCleanup(
                projectURL
            )
        )
    }

    // MARK: - formatBytes

    @MainActor
    func testFormatBytesKB() {
        // 512 bytes -> "512 bytes" (ByteCountFormatter shows bytes under 1 KB)
        let result = AppDelegate.formatBytes(512)
        XCTAssertTrue(result.contains("bytes"), "Expected bytes, got: \(result)")
    }

    @MainActor
    func testFormatBytesAboveKBThreshold() {
        let twoKB: UInt64 = 2_048
        let result = AppDelegate.formatBytes(twoKB)
        XCTAssertTrue(result.contains("KB"), "Expected KB, got: \(result)")
    }

    @MainActor
    func testFormatBytesMB() {
        // 5 MB
        let fiveMB: UInt64 = 5 * 1024 * 1024
        let result = AppDelegate.formatBytes(fiveMB)
        XCTAssertTrue(result.contains("MB"), "Expected MB, got: \(result)")
        XCTAssertTrue(result.hasPrefix("5"), "Expected ~5 MB, got: \(result)")
    }

    @MainActor
    func testFormatBytesGB() {
        // 2 GB
        let twoGB: UInt64 = 2 * 1024 * 1024 * 1024
        let result = AppDelegate.formatBytes(twoGB)
        XCTAssertTrue(result.contains("GB"), "Expected GB, got: \(result)")
        XCTAssertTrue(result.hasPrefix("2"), "Expected ~2 GB, got: \(result)")
    }

    @MainActor
    func testFormatBytesZero() {
        let result = AppDelegate.formatBytes(0)
        XCTAssertTrue(result.contains("KB"), "Zero bytes should format as KB: \(result)")
    }

    private func makeOwnedTemp(prefix: String) throws -> URL {
        let root = ProjectTempDirectory.tempRoot(for: projectURL)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return try OwnedWorkDirectoryMarkerStore.createDirectory(
            .init(
                projectURL: projectURL,
                parentDirectoryURL: root,
                prefix: prefix,
                runID: UUID(),
                processIdentity: .init(
                    processIdentifier: 999,
                    processStartTime: 1,
                    bootSessionID: "test-boot"
                ),
                state: .active,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: "test",
                toolVersion: "1"
            )
        )
    }
}

private final class ThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool?

    var value: Bool? { lock.withLock { storage } }

    func record(_ value: Bool) {
        lock.withLock { storage = value }
    }
}

private actor SequencedCleanupRunner {
    private var callCount = 0
    private var results:
        [Int: CheckedContinuation<
            ProjectStorageAutomaticCleanupResult,
            Never
        >] = [:]
    private var callWaiters:
        [(Int, CheckedContinuation<Void, Never>)] = []

    func run() async -> ProjectStorageAutomaticCleanupResult {
        let call = callCount
        callCount += 1
        let ready = callWaiters.filter { $0.0 <= callCount }
        callWaiters.removeAll { $0.0 <= callCount }
        ready.forEach { $0.1.resume() }
        return await withCheckedContinuation {
            results[call] = $0
        }
    }

    func waitForCallCount(_ expected: Int) async {
        guard callCount < expected else { return }
        await withCheckedContinuation {
            callWaiters.append((expected, $0))
        }
    }

    func resume(call: Int) {
        results.removeValue(forKey: call)?.resume(
            returning: .init(
                state: .noEligibleEntries,
                scannedEntryCount: 0,
                selectedEntryCount: 0,
                warnings: [],
                summaryURL: nil,
                provenanceURL: nil
            )
        )
    }
}
