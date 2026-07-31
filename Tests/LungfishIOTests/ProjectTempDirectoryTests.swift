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

    func testFindProjectRootFromDeeplyNestedPath() throws {
        // Create a path 25+ levels deep — deeper than the old maxWalkDepth of 20
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        var deepPath = projectDir
        for i in 0..<25 {
            deepPath = deepPath.appendingPathComponent("level-\(i)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: deepPath, withIntermediateDirectories: true)

        let found = ProjectTempDirectory.findProjectRoot(deepPath)
        XCTAssertNotNil(found, "Should find .lungfish root even from 25+ levels deep")
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

    func testCleanAllRefusesActiveAndUnmarkedChildren() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Create a few temp dirs and a file inside them
        let dir1 = try ProjectTempDirectory.create(prefix: "a-", in: projectDir)
        let dir2 = try ProjectTempDirectory.create(prefix: "b-", in: projectDir)
        try "hello".write(to: dir1.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        try "world".write(to: dir2.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        let unmarked = ProjectTempDirectory.tempRoot(for: projectDir)
            .appendingPathComponent("legacy-unmarked", isDirectory: true)
        try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: false)

        try ProjectTempDirectory.cleanAll(in: projectDir)

        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir2.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unmarked.path),
            "A broad compatibility cleanup must not infer ownership from location alone"
        )
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

    // MARK: - TempScopePolicy

    func testRequireProjectContextThrowsWithoutProject() throws {
        let unrelated = testRoot.appendingPathComponent("not-a-project", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try ProjectTempDirectory.create(
                prefix: "test-", contextURL: unrelated, policy: .requireProjectContext
            )
        ) { error in
            guard case ProjectTempError.projectContextRequired = error else {
                XCTFail("Expected projectContextRequired error, got \(error)")
                return
            }
        }
    }

    func testRequireProjectContextThrowsWithNilContext() throws {
        XCTAssertThrowsError(
            try ProjectTempDirectory.create(
                prefix: "test-", contextURL: nil, policy: .requireProjectContext
            )
        ) { error in
            guard case ProjectTempError.projectContextRequired = error else {
                XCTFail("Expected projectContextRequired error, got \(error)")
                return
            }
        }
    }

    func testRequireProjectContextSucceedsWithProject() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let created = try ProjectTempDirectory.create(
            prefix: "req-", contextURL: projectDir, policy: .requireProjectContext
        )
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        XCTAssertTrue(created.standardizedFileURL.path.hasPrefix(tmpRoot.standardizedFileURL.path))
    }

    func testPreferProjectContextFallsBackToSystemTemp() throws {
        let unrelated = testRoot.appendingPathComponent("not-a-project", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        let created = try ProjectTempDirectory.create(
            prefix: "pref-", contextURL: unrelated, policy: .preferProjectContext
        )
        defer { try? FileManager.default.removeItem(at: created) }
        XCTAssertFalse(created.path.contains(".lungfish"))
    }

    func testPreferProjectContextUsesProjectWhenAvailable() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let created = try ProjectTempDirectory.create(
            prefix: "pref-", contextURL: projectDir, policy: .preferProjectContext
        )
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        XCTAssertTrue(created.standardizedFileURL.path.hasPrefix(tmpRoot.standardizedFileURL.path))
    }

    func testSystemOnlyAlwaysUsesSystemTemp() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let created = try ProjectTempDirectory.create(
            prefix: "sys-", contextURL: projectDir, policy: .systemOnly
        )
        defer { try? FileManager.default.removeItem(at: created) }
        // Even with a valid project context, systemOnly uses system temp
        XCTAssertFalse(created.path.contains(".lungfish"))
    }

    // MARK: - Provenance Marker

    func testMarkerIsWrittenOnCreate() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let created = try ProjectTempDirectory.create(
            prefix: "marker-", contextURL: projectDir, policy: .requireProjectContext
        )
        let markerURL = created.appendingPathComponent(ProjectTempDirectory.TempOriginMarker.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path), "Marker file should exist")
    }

    func testMarkerContainsCorrectMetadata() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let created = try ProjectTempDirectory.create(
            prefix: "meta-", contextURL: projectDir, policy: .requireProjectContext
        )
        let marker = ProjectTempDirectory.readMarker(from: created)
        XCTAssertNotNil(marker)
        XCTAssertEqual(marker?.version, 1)
        XCTAssertEqual(marker?.prefix, "meta-")
        XCTAssertEqual(marker?.policy, .requireProjectContext)
        XCTAssertNotNil(marker?.resolvedProjectPath)
        XCTAssertEqual(marker?.pid, ProcessInfo.processInfo.processIdentifier)
    }

    func testLegacyCreateUsesAuthoritativeOwnedMarkerForProjectLocalDirectory() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let created = try ProjectTempDirectory.create(prefix: "legacy-", in: projectDir)
        let marker = try OwnedWorkDirectoryMarkerStore.load(
            from: created,
            expectedProjectURL: projectDir
        )
        XCTAssertEqual(marker.schemaVersion, OwnedWorkDirectoryMarker.schemaVersion)
        XCTAssertEqual(marker.directoryIdentity, try FileSystemObjectIdentity.noFollow(created))
    }

    func testReadMarkerReturnsNilForMissingFile() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let marker = ProjectTempDirectory.readMarker(from: projectDir)
        XCTAssertNil(marker)
    }

    func testCompatibilityWrapperWritesMarker() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // createFromContext now routes through the policy API
        let created = try ProjectTempDirectory.createFromContext(prefix: "compat-", contextURL: projectDir)
        let marker = ProjectTempDirectory.readMarker(from: created)
        XCTAssertNotNil(marker)
        XCTAssertEqual(marker?.policy, .preferProjectContext)
        let owned = try OwnedWorkDirectoryMarkerStore.load(
            from: created,
            expectedProjectURL: projectDir
        )
        XCTAssertEqual(owned.state, .active)
        XCTAssertEqual(owned.toolName, "ProjectTempDirectory")
        XCTAssertFalse(owned.toolVersion.isEmpty)
    }

    // MARK: - cleanStale

    func testCleanStaleRefusesUnmarkedLegacyChildren() throws {
        let projectDir = testRoot.appendingPathComponent("myproject.lungfish", isDirectory: true)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let staleDir = tmpRoot.appendingPathComponent("legacy-unmarked", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: false)

        // Backdate staleDir modification date to 25 hours ago
        let twentyFiveHoursAgo = Date(timeIntervalSinceNow: -25 * 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: twentyFiveHoursAgo],
            ofItemAtPath: staleDir.path
        )

        // Clean entries older than 24 hours
        try ProjectTempDirectory.cleanStale(in: projectDir, olderThan: 24 * 3600)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staleDir.path),
            "Age alone must never authorize removal of an unmarked legacy child"
        )
    }

    func testCleanAllDetachesVerifiedTerminalDirectoryAndPreservesSwapReplacement() throws {
        let projectDir = testRoot.appendingPathComponent("swap.lungfish", isDirectory: true)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let terminal = try OwnedWorkDirectoryMarkerStore.createDirectory(
            OwnedWorkDirectoryCreationRequest(
                projectURL: projectDir,
                parentDirectoryURL: tmpRoot,
                prefix: "terminal-",
                runID: UUID(),
                processIdentity: try .current(),
                state: .completed,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: "test",
                toolVersion: "1"
            )
        )
        try Data("owned".utf8).write(to: terminal.appendingPathComponent("owned.txt"))
        let held = tmpRoot.appendingPathComponent("held-original", isDirectory: true)

        try ProjectTempDirectory.cleanAll(in: projectDir) { candidate in
            guard candidate.lastPathComponent == terminal.lastPathComponent else { return }
            try FileManager.default.moveItem(at: candidate, to: held)
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
            try Data("replacement".utf8).write(
                to: candidate.appendingPathComponent("replacement.txt")
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: terminal.appendingPathComponent("replacement.txt")),
            Data("replacement".utf8),
            "A substituted inode must be restored and must never be removed"
        )
        XCTAssertEqual(
            try Data(contentsOf: held.appendingPathComponent("owned.txt")),
            Data("owned".utf8)
        )
    }

    func testCleanAllRemovesTerminalAttestedDirectoryWithoutFollowingPayloadSymlink() throws {
        let projectDir = testRoot.appendingPathComponent("terminal.lungfish", isDirectory: true)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let terminal = try OwnedWorkDirectoryMarkerStore.createDirectory(
            OwnedWorkDirectoryCreationRequest(
                projectURL: projectDir,
                parentDirectoryURL: tmpRoot,
                prefix: "terminal-",
                runID: UUID(),
                processIdentity: try .current(),
                state: .failed,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: "test",
                toolVersion: "1"
            )
        )
        let outside = testRoot.appendingPathComponent("outside.txt")
        try Data("preserve".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: terminal.appendingPathComponent("linked.txt"),
            withDestinationURL: outside
        )

        try ProjectTempDirectory.cleanAll(in: projectDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: terminal.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("preserve".utf8))
        let remaining = try FileManager.default.contentsOfDirectory(
            at: tmpRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(
            remaining.contains { $0.lastPathComponent.contains("cleanup-pending") }
        )
    }

    func testCleanAllSurfacesUnexpectedDetachFailureAtExactCandidatePath() throws {
        let projectDir = testRoot.appendingPathComponent("detach-error.lungfish", isDirectory: true)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let terminal = try makeTerminalDirectory(project: projectDir, parent: tmpRoot)

        for expectedCode in [EACCES, EIO] {
            XCTAssertThrowsError(
                try ProjectTempDirectory.cleanAll(
                    in: projectDir,
                    beforeDetach: { _ in },
                    operations: .init(
                        detach: { _, _, _ in
                            errno = expectedCode
                            return -1
                        },
                        syncParent: { Darwin.fsync($0) }
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? OwnedWorkDirectoryMarkerError,
                    .systemFailure(
                        path: terminal.path,
                        operation: "detach owned temp directory for cleanup",
                        code: expectedCode
                    )
                )
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: terminal.path))
    }

    func testCleanAllParentSyncFailureLeavesNamedRecoverableQuarantine() throws {
        let projectDir = testRoot.appendingPathComponent("sync-error.lungfish", isDirectory: true)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let terminal = try makeTerminalDirectory(project: projectDir, parent: tmpRoot)
        try Data("recoverable".utf8).write(
            to: terminal.appendingPathComponent("payload.txt")
        )

        XCTAssertThrowsError(
            try ProjectTempDirectory.cleanAll(
                in: projectDir,
                beforeDetach: { _ in },
                operations: .init(
                    detach: ProjectTempDirectory.CleanupOperations.defaultDetach,
                    syncParent: { _ in
                        errno = EIO
                        return -1
                    }
                )
            )
        ) { error in
            guard case let OwnedWorkDirectoryMarkerError.cleanupQuarantineRetained(
                path,
                operation,
                code
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(path.contains(".lungfish-cleanup-pending-"))
            XCTAssertEqual(operation, "fsync cleanup quarantine parent")
            XCTAssertEqual(code, EIO)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: terminal.path))
        let quarantine = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: tmpRoot,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix(".lungfish-cleanup-pending-") }
        )
        XCTAssertEqual(
            try Data(contentsOf: quarantine.appendingPathComponent("payload.txt")),
            Data("recoverable".utf8)
        )
    }

    func testCleanAllCandidateOpenFailureReportsExactPath() throws {
        let projectDir = testRoot.appendingPathComponent("open-error.lungfish", isDirectory: true)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let terminal = try makeTerminalDirectory(project: projectDir, parent: tmpRoot)

        for expectedCode in [EACCES, EIO] {
            XCTAssertThrowsError(
                try ProjectTempDirectory.cleanAll(
                    in: projectDir,
                    beforeDetach: { _ in },
                    operations: .init(
                        openCandidate: { _, _ in
                            errno = expectedCode
                            return -1
                        }
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? OwnedWorkDirectoryMarkerError,
                    .systemFailure(
                        path: terminal.path,
                        operation: "open owned temp cleanup candidate",
                        code: expectedCode
                    )
                )
            }
        }
    }

    func testCleanAllFinalInspectionFailureReportsUncertainQuarantineLocation() throws {
        let projectDir = testRoot.appendingPathComponent("inspect-error.lungfish", isDirectory: true)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        _ = try makeTerminalDirectory(project: projectDir, parent: tmpRoot)

        XCTAssertThrowsError(
            try ProjectTempDirectory.cleanAll(
                in: projectDir,
                beforeDetach: { _ in },
                operations: .init(
                    inspectFinalQuarantine: { _, _, _ in
                        errno = EIO
                        return -1
                    }
                )
            )
        ) { error in
            guard case let OwnedWorkDirectoryMarkerError.cleanupQuarantineLocationUncertain(
                lastKnownPath,
                operation,
                code
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(lastKnownPath.contains(".lungfish-cleanup-pending-"))
            XCTAssertEqual(operation, "inspect partially cleaned temp cleanup quarantine")
            XCTAssertEqual(code, EIO)
        }
        XCTAssertNotNil(try tempCleanupQuarantine(in: tmpRoot))
    }

    func testCleanAllMovedFinalQuarantineReportsLastKnownLocation() throws {
        let projectDir = testRoot.appendingPathComponent("moved-final.lungfish", isDirectory: true)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        _ = try makeTerminalDirectory(project: projectDir, parent: tmpRoot)
        let held = tmpRoot.appendingPathComponent("held-partially-cleaned", isDirectory: true)

        XCTAssertThrowsError(
            try ProjectTempDirectory.cleanAll(
                in: projectDir,
                beforeDetach: { _ in },
                operations: .init(
                    beforeFinalInspection: { quarantine in
                        try FileManager.default.moveItem(at: quarantine, to: held)
                    }
                )
            )
        ) { error in
            guard case let OwnedWorkDirectoryMarkerError.cleanupQuarantineLocationUncertain(
                lastKnownPath,
                operation,
                code
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(lastKnownPath.contains(".lungfish-cleanup-pending-"))
            XCTAssertEqual(operation, "inspect partially cleaned temp cleanup quarantine")
            XCTAssertEqual(code, ENOENT)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
    }

    func testCleanAllVanishedFinalQuarantineReportsLastKnownLocation() throws {
        let projectDir = testRoot.appendingPathComponent("vanished-final.lungfish", isDirectory: true)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        _ = try makeTerminalDirectory(project: projectDir, parent: tmpRoot)

        XCTAssertThrowsError(
            try ProjectTempDirectory.cleanAll(
                in: projectDir,
                beforeDetach: { _ in },
                operations: .init(
                    beforeFinalInspection: { quarantine in
                        try FileManager.default.removeItem(at: quarantine)
                    }
                )
            )
        ) { error in
            guard case let OwnedWorkDirectoryMarkerError.cleanupQuarantineLocationUncertain(
                lastKnownPath,
                operation,
                code
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(lastKnownPath.contains(".lungfish-cleanup-pending-"))
            XCTAssertEqual(operation, "inspect partially cleaned temp cleanup quarantine")
            XCTAssertEqual(code, ENOENT)
            XCTAssertFalse(FileManager.default.fileExists(atPath: lastKnownPath))
        }
    }

    func testCleanAllRmdirENOENTReportsUncertainQuarantineLocation() throws {
        let projectDir = testRoot.appendingPathComponent("rmdir-enoent.lungfish", isDirectory: true)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        _ = try makeTerminalDirectory(project: projectDir, parent: tmpRoot)

        XCTAssertThrowsError(
            try ProjectTempDirectory.cleanAll(
                in: projectDir,
                beforeDetach: { _ in },
                operations: .init(
                    removeQuarantine: { descriptor, name in
                        let status = ProjectTempDirectory.CleanupOperations
                            .defaultRemoveQuarantine(descriptor, name)
                        XCTAssertEqual(status, 0)
                        errno = ENOENT
                        return -1
                    }
                )
            )
        ) { error in
            guard case let OwnedWorkDirectoryMarkerError.cleanupQuarantineLocationUncertain(
                lastKnownPath,
                operation,
                code
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(lastKnownPath.contains(".lungfish-cleanup-pending-"))
            XCTAssertEqual(operation, "remove partially cleaned temp cleanup quarantine")
            XCTAssertEqual(code, ENOENT)
            XCTAssertFalse(FileManager.default.fileExists(atPath: lastKnownPath))
        }
    }

    func testCleanAllQuarantineRmdirFailureRetainsAndReportsPath() throws {
        let projectDir = testRoot.appendingPathComponent("rmdir-error.lungfish", isDirectory: true)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        _ = try makeTerminalDirectory(project: projectDir, parent: tmpRoot)

        XCTAssertThrowsError(
            try ProjectTempDirectory.cleanAll(
                in: projectDir,
                beforeDetach: { _ in },
                operations: .init(
                    removeQuarantine: { _, _ in
                        errno = EACCES
                        return -1
                    }
                )
            )
        ) { error in
            guard case let OwnedWorkDirectoryMarkerError.cleanupQuarantineRetained(
                path,
                operation,
                code
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(path.contains(".lungfish-cleanup-pending-"))
            XCTAssertEqual(operation, "remove partially cleaned temp cleanup quarantine")
            XCTAssertEqual(code, EACCES)
        }
        XCTAssertNotNil(try tempCleanupQuarantine(in: tmpRoot))
    }

    func testCleanAllRemovalSyncFailureReportsUncertainDisposition() throws {
        let projectDir = testRoot.appendingPathComponent("final-sync.lungfish", isDirectory: true)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectDir)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        _ = try makeTerminalDirectory(project: projectDir, parent: tmpRoot)
        let sync = TempCleanupSyncSequence()

        XCTAssertThrowsError(
            try ProjectTempDirectory.cleanAll(
                in: projectDir,
                beforeDetach: { _ in },
                operations: .init(syncParent: { sync.sync($0) })
            )
        ) { error in
            guard case let OwnedWorkDirectoryMarkerError.cleanupRemovalDurabilityUncertain(
                path,
                operation,
                code
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(path.contains(".lungfish-cleanup-pending-"))
            XCTAssertEqual(operation, "fsync removed temp cleanup entry")
            XCTAssertEqual(code, EIO)
        }
    }

    private func makeTerminalDirectory(project: URL, parent: URL) throws -> URL {
        try OwnedWorkDirectoryMarkerStore.createDirectory(
            OwnedWorkDirectoryCreationRequest(
                projectURL: project,
                parentDirectoryURL: parent,
                prefix: "terminal-",
                runID: UUID(),
                processIdentity: try .current(),
                state: .completed,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: "test",
                toolVersion: "1"
            )
        )
    }

    private func tempCleanupQuarantine(in root: URL) throws -> URL? {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix(".lungfish-cleanup-pending-") }
    }
}

private final class TempCleanupSyncSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func sync(_ descriptor: Int32) -> Int32 {
        lock.withLock {
            callCount += 1
            if callCount == 2 {
                errno = EIO
                return -1
            }
            return Darwin.fsync(descriptor)
        }
    }
}
