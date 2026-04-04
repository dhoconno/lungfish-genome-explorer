// ProjectTempCleanupTests.swift — Tests for project-aware temp file cleanup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

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

    // MARK: - cleanAll removes .tmp/

    func testCleanAllRemovesTmpDirectory() throws {
        // Create temp dirs with files inside the project .tmp/
        let dir1 = try ProjectTempDirectory.create(prefix: "classify-", in: projectURL)
        try Data(repeating: 0xAA, count: 512).write(to: dir1.appendingPathComponent("out.txt"))
        let dir2 = try ProjectTempDirectory.create(prefix: "map-", in: projectURL)
        try Data(repeating: 0xBB, count: 256).write(to: dir2.appendingPathComponent("out.bam"))

        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpRoot.path))

        // Act
        try ProjectTempDirectory.cleanAll(in: projectURL)

        // Assert
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpRoot.path),
                       ".tmp/ should be completely removed after cleanAll")
    }

    func testCleanAllIsIdempotentOnEmptyProject() throws {
        // No .tmp/ directory exists
        XCTAssertNoThrow(try ProjectTempDirectory.cleanAll(in: projectURL))
        // Call again — still no error
        XCTAssertNoThrow(try ProjectTempDirectory.cleanAll(in: projectURL))
    }

    // MARK: - diskUsage

    func testDiskUsageReturnsCorrectByteCount() throws {
        let dir = try ProjectTempDirectory.create(prefix: "usage-", in: projectURL)
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

    func testCleanStaleRemovesOldDirectoriesOnly() throws {
        let recentDir = try ProjectTempDirectory.create(prefix: "recent-", in: projectURL)
        let staleDir = try ProjectTempDirectory.create(prefix: "stale-", in: projectURL)

        // Backdate staleDir to 25 hours ago
        let twentyFiveHoursAgo = Date(timeIntervalSinceNow: -25 * 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: twentyFiveHoursAgo],
            ofItemAtPath: staleDir.path
        )

        // Clean entries older than 24 hours
        try ProjectTempDirectory.cleanStale(in: projectURL, olderThan: 24 * 3600)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDir.path),
                       "Stale directory (25 h old) should be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentDir.path),
                      "Recent directory should still exist")
    }

    func testCleanStaleKeepsAllRecentDirectories() throws {
        let dir1 = try ProjectTempDirectory.create(prefix: "a-", in: projectURL)
        let dir2 = try ProjectTempDirectory.create(prefix: "b-", in: projectURL)

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

    // MARK: - formatBytes

    @MainActor
    func testFormatBytesKB() {
        // 512 bytes -> "1 KB" (rounds up from 0.5)
        let result = AppDelegate.formatBytes(512)
        XCTAssertTrue(result.hasSuffix("KB"), "Expected KB suffix, got: \(result)")
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
}
