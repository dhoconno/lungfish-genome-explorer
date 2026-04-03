// ProjectTempDirectoryTests.swift - Tests for project-local temp directory utility
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class ProjectTempDirectoryTests: XCTestCase {

    // MARK: - Helpers

    private var testRoot: URL!

    override func setUp() {
        super.setUp()
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectTempDirTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testRoot)
        super.tearDown()
    }

    // MARK: - findProjectRoot

    func testFindProjectRootFromDerivativesPath() throws {
        // Build: testRoot/myproject.lungfish/Downloads/sample.lungfishfastq/derivatives/esviritu-ABC123
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        let deepPath = projectDir
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("sample.lungfishfastq", isDirectory: true)
            .appendingPathComponent("derivatives", isDirectory: true)
            .appendingPathComponent("esviritu-ABC123", isDirectory: true)
        try FileManager.default.createDirectory(at: deepPath, withIntermediateDirectories: true)

        let found = ProjectTempDirectory.findProjectRoot(deepPath)
        XCTAssertNotNil(found, "Should find the .lungfish project directory from a deep derivatives path")
        XCTAssertEqual(found?.standardizedFileURL, projectDir.standardizedFileURL)
    }

    func testFindProjectRootFromImportsPath() throws {
        // Build: testRoot/myproject.lungfish/Imports/naomgs-test
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        let importsPath = projectDir
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("naomgs-test", isDirectory: true)
        try FileManager.default.createDirectory(at: importsPath, withIntermediateDirectories: true)

        let found = ProjectTempDirectory.findProjectRoot(importsPath)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.standardizedFileURL, projectDir.standardizedFileURL)
    }

    func testFindProjectRootReturnsNilOutsideProject() throws {
        // tempDir has no .lungfish ancestor
        let unrelated = testRoot.appendingPathComponent("not-a-project", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        let found = ProjectTempDirectory.findProjectRoot(unrelated)
        XCTAssertNil(found, "Should return nil when no .lungfish ancestor exists")
    }

    func testFindProjectRootFromProjectItself() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let found = ProjectTempDirectory.findProjectRoot(projectDir)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.standardizedFileURL, projectDir.standardizedFileURL)
    }

    // MARK: - tempRoot

    func testTempRootReturnsCorrectPath() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        XCTAssertEqual(tmpRoot.lastPathComponent, ".tmp")
        XCTAssertEqual(tmpRoot.deletingLastPathComponent().standardizedFileURL,
                       projectDir.standardizedFileURL)
    }

    // MARK: - create

    func testCreateMakesDirectoryInsideProjectTmp() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let created = try ProjectTempDirectory.create(prefix: "test-", in: projectDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path),
                      "Created directory should exist on disk")
        // Verify it is under .tmp/
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        XCTAssertTrue(created.standardizedFileURL.path.hasPrefix(tmpRoot.standardizedFileURL.path),
                      "Created directory should be under the .tmp/ root")
        XCTAssertTrue(created.lastPathComponent.hasPrefix("test-"),
                      "Directory name should start with the given prefix")
    }

    func testCreateFallsBackToSystemTempWhenNilProject() throws {
        let created = try ProjectTempDirectory.create(prefix: "fallback-", in: nil)
        defer { try? FileManager.default.removeItem(at: created) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path),
                      "Fallback directory should exist on disk")
        // Should NOT be under any .lungfish/.tmp path
        XCTAssertFalse(created.path.contains(".lungfish"),
                       "Fallback should not reference a .lungfish project")
    }

    func testCreateFromAnyURLInsideProject() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        let deepDir = projectDir
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("some-bundle.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)

        let created = try ProjectTempDirectory.createFromContext(prefix: "ctx-", contextURL: deepDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        XCTAssertTrue(created.standardizedFileURL.path.hasPrefix(tmpRoot.standardizedFileURL.path),
                      "Should land under the project .tmp/ resolved from context URL")
    }

    // MARK: - cleanAll

    func testCleanAllRemovesEntireTmpDirectory() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Create a few temp dirs and a file inside them
        let dir1 = try ProjectTempDirectory.create(prefix: "a-", in: projectDir)
        let dir2 = try ProjectTempDirectory.create(prefix: "b-", in: projectDir)
        try "hello".write(to: dir1.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        try "world".write(to: dir2.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        try ProjectTempDirectory.cleanAll(in: projectDir)

        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpRoot.path),
                       "Entire .tmp/ directory should be removed after cleanAll")
    }

    func testCleanAllIsIdempotent() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // First call — nothing exists yet
        XCTAssertNoThrow(try ProjectTempDirectory.cleanAll(in: projectDir),
                         "cleanAll on non-existent .tmp/ should not throw")
        // Second call — still nothing
        XCTAssertNoThrow(try ProjectTempDirectory.cleanAll(in: projectDir),
                         "Second cleanAll should also not throw")
    }

    // MARK: - diskUsage

    func testDiskUsageReturnsNonZeroAfterCreate() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let dir = try ProjectTempDirectory.create(prefix: "usage-", in: projectDir)
        // Write 1 KB of data
        let data = Data(repeating: 0xAB, count: 1024)
        try data.write(to: dir.appendingPathComponent("payload.bin"))

        let usage = ProjectTempDirectory.diskUsage(in: projectDir)
        XCTAssertGreaterThan(usage, 0, "Disk usage should be > 0 after writing data")
    }

    func testDiskUsageReturnsZeroWhenNoTmp() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        // No .tmp dir created

        let usage = ProjectTempDirectory.diskUsage(in: projectDir)
        XCTAssertEqual(usage, 0, "Disk usage should be 0 when .tmp/ does not exist")
    }

    // MARK: - cleanStale

    func testCleanStaleRemovesOldDirectoriesOnly() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let recentDir = try ProjectTempDirectory.create(prefix: "recent-", in: projectDir)
        let staleDir  = try ProjectTempDirectory.create(prefix: "stale-", in: projectDir)

        // Backdate staleDir modification date to 25 hours ago
        let twentyFiveHoursAgo = Date(timeIntervalSinceNow: -25 * 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: twentyFiveHoursAgo],
            ofItemAtPath: staleDir.path
        )

        // Clean entries older than 24 hours
        try ProjectTempDirectory.cleanStale(in: projectDir, olderThan: 24 * 3600)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDir.path),
                       "Stale directory (25h old) should have been removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentDir.path),
                      "Recent directory should NOT have been removed")
    }
}
