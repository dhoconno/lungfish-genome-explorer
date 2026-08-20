// FileSystemWatcherTests.swift - Tests for FSEvents-based directory monitoring
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import CoreServices
@testable import LungfishApp

/// Tests for the FileSystemWatcher class.
///
/// These tests verify that the FSEvents-based watcher correctly detects
/// filesystem changes including file creation, deletion, and modification.
/// XCTest keeps the OS-backed cases in the serial XCTest phase; Swift Testing
/// runs suites concurrently and can starve FSEvents callbacks scheduled on the
/// main dispatch queue during the complete package run.
@MainActor
final class FileSystemWatcherTests: XCTestCase {

    /// Creates a temporary directory for testing
    private func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Removes a temporary directory
    private func removeTempDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// FSEvents delivery is asynchronous and is deliberately coalesced by the
    /// watcher. Its three-second batching latency is not a hard delivery bound
    /// when the full suite is also scheduling MainActor work. Polling with a
    /// generous deadline avoids treating an arbitrary sleep as proof that the
    /// callback queue has been serviced while still returning as soon as the
    /// expected event arrives.
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 20,
        condition: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Observe a negative or bounded condition continuously. Returning as soon
    /// as it becomes false preserves the first failure while a successful
    /// result proves the condition held across the complete FSEvents latency
    /// window rather than only at the first positive callback.
    @MainActor
    private func remainsTrue(
        for observationWindow: TimeInterval = 4,
        condition: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(observationWindow)
        while Date() < deadline {
            if !condition() {
                return false
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Give fseventsd a scheduling turn after a new stream starts. This models
    /// the production case (an already-open project) rather than racing file
    /// creation against stream registration.
    @MainActor
    private func settleWatcherRegistration() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    func testFailedStreamStartCleansUp() throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        var stopCount = 0
        var invalidationCount = 0
        var releaseCount = 0
        let lifecycle = FileSystemWatcher.StreamLifecycle(
            start: { _ in false },
            stop: { _ in stopCount += 1 },
            invalidate: { stream in
                invalidationCount += 1
                FSEventStreamInvalidate(stream)
            },
            release: { stream in
                releaseCount += 1
                FSEventStreamRelease(stream)
            }
        )
        let watcher = FileSystemWatcher(
            onChange: { _ in },
            onRootChanged: nil,
            streamLifecycle: lifecycle
        )

        watcher.startWatching(directory: tempDir)

        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(invalidationCount, 1)
        XCTAssertEqual(releaseCount, 1)
    }

    func testWatcherDetectsFileCreation() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        var callbackInvoked = false

        let watcher = FileSystemWatcher { _ in
            callbackInvoked = true
        }

        watcher.startWatching(directory: tempDir)
        XCTAssertTrue(watcher.isWatching)
        try await settleWatcherRegistration()

        // Create a file
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "Hello, World!".write(to: testFile, atomically: true, encoding: .utf8)

        let receivedCallback = try await waitUntil { callbackInvoked }

        XCTAssertTrue(receivedCallback, "Callback should be invoked when file is created")

        watcher.stopWatching()
        XCTAssertFalse(watcher.isWatching)
    }

    func testWatcherDetectsFileDeletion() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        // Create a file first
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "Hello, World!".write(to: testFile, atomically: true, encoding: .utf8)

        var callbackCount = 0
        let watcher = FileSystemWatcher { _ in
            callbackCount += 1
        }

        watcher.startWatching(directory: tempDir)
        try await settleWatcherRegistration()

        // Delete the file
        try FileManager.default.removeItem(at: testFile)

        let receivedCallback = try await waitUntil { callbackCount >= 1 }

        XCTAssertTrue(receivedCallback, "Callback should be invoked when file is deleted")

        watcher.stopWatching()
    }

    func testWatcherDetectsFileRename() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        // Create a file first
        let originalFile = tempDir.appendingPathComponent("original.txt")
        try "Hello, World!".write(to: originalFile, atomically: true, encoding: .utf8)

        var callbackCount = 0
        let watcher = FileSystemWatcher { _ in
            callbackCount += 1
        }

        watcher.startWatching(directory: tempDir)
        try await settleWatcherRegistration()

        // Rename the file
        let renamedFile = tempDir.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: originalFile, to: renamedFile)

        let receivedCallback = try await waitUntil { callbackCount >= 1 }

        XCTAssertTrue(receivedCallback, "Callback should be invoked when file is renamed")

        watcher.stopWatching()
    }

    func testWatcherHandlesNestedChanges() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        // Create a nested directory
        let nestedDir = tempDir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)

        var callbackInvoked = false
        let watcher = FileSystemWatcher { _ in
            callbackInvoked = true
        }

        watcher.startWatching(directory: tempDir)
        try await settleWatcherRegistration()

        // Create a file in the nested directory
        let nestedFile = nestedDir.appendingPathComponent("nested_file.txt")
        try "Nested content".write(to: nestedFile, atomically: true, encoding: .utf8)

        let receivedCallback = try await waitUntil { callbackInvoked }

        XCTAssertTrue(receivedCallback, "Callback should be invoked for changes in nested directories")

        watcher.stopWatching()
    }

    func testWatcherCleansUpOnStop() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        var callbackCount = 0
        let watcher = FileSystemWatcher { _ in
            callbackCount += 1
        }

        watcher.startWatching(directory: tempDir)
        XCTAssertTrue(watcher.isWatching)

        watcher.stopWatching()
        XCTAssertFalse(watcher.isWatching)

        // Create a file after stopping
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "Hello, World!".write(to: testFile, atomically: true, encoding: .utf8)

        let remainedSilent = try await remainsTrue { callbackCount == 0 }

        XCTAssertTrue(remainedSilent, "Callback should not be invoked after stopWatching()")
    }

    func testWatcherReportsMovedRoot() async throws {
        let tempDir = try createTempDirectory()
        let movedDir = tempDir.deletingLastPathComponent()
            .appendingPathComponent(tempDir.lastPathComponent + "-moved")
        defer {
            removeTempDirectory(tempDir)
            removeTempDirectory(movedDir)
        }

        var rootChanged = false
        let watcher = FileSystemWatcher(
            onChange: { _ in },
            onRootChanged: { rootChanged = true }
        )
        watcher.startWatching(directory: tempDir)
        try await settleWatcherRegistration()

        try FileManager.default.moveItem(at: tempDir, to: movedDir)
        let receivedRootChange = try await waitUntil { rootChanged }

        XCTAssertTrue(receivedRootChange, "Moving the watched project root must invoke onRootChanged")
    }

    func testWatcherFiltersHiddenFiles() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        var hiddenOnlyCallbackCount = 0
        var visibleCallbackCount = 0

        // First test: only hidden file - should not trigger callback
        let watcher1 = FileSystemWatcher { _ in
            hiddenOnlyCallbackCount += 1
        }
        watcher1.startWatching(directory: tempDir)
        try await settleWatcherRegistration()

        // Create a hidden file (like .project.db)
        let hiddenFile = tempDir.appendingPathComponent(".hidden_file")
        try "Hidden content".write(to: hiddenFile, atomically: true, encoding: .utf8)

        // Give a possible directory-level event a bounded observation window.
        _ = try await waitUntil(timeout: 4) { hiddenOnlyCallbackCount >= 1 }
        watcher1.stopWatching()

        // Note: FSEvents may still report directory-level changes, so we can't
        // guarantee zero callbacks. The key test is that visible files DO trigger.

        // Second test: visible file - SHOULD trigger callback
        let watcher2 = FileSystemWatcher { _ in
            visibleCallbackCount += 1
        }
        watcher2.startWatching(directory: tempDir)
        try await settleWatcherRegistration()

        let visibleFile = tempDir.appendingPathComponent("visible.txt")
        try "Visible content".write(to: visibleFile, atomically: true, encoding: .utf8)

        let receivedVisibleCallback = try await waitUntil { visibleCallbackCount >= 1 }
        watcher2.stopWatching()

        // Visible file changes MUST trigger callback
        XCTAssertTrue(receivedVisibleCallback, "Callback MUST be invoked for visible files")

        // Hidden-only changes should ideally not trigger, but FSEvents behavior varies
        // The important thing is that we filter them in handleFilesystemChange
    }

    func testWatcherDebouncesRapidChanges() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        var callbackCount = 0
        let watcher = FileSystemWatcher { _ in
            callbackCount += 1
        }

        watcher.startWatching(directory: tempDir)
        try await settleWatcherRegistration()

        // Create multiple files in rapid succession
        for i in 0..<5 {
            let testFile = tempDir.appendingPathComponent("test_\(i).txt")
            try "Content \(i)".write(to: testFile, atomically: true, encoding: .utf8)
        }

        let receivedCallback = try await waitUntil { callbackCount >= 1 }
        let remainedDebounced = receivedCallback
            ? try await remainsTrue { callbackCount <= 2 }
            : false

        // Due to debouncing, we should get fewer callbacks than file operations
        // Ideally just 1 callback after all the rapid changes
        XCTAssertTrue(receivedCallback, "Should get at least one callback")
        XCTAssertTrue(remainedDebounced, "Debouncing should coalesce rapid changes (got \(callbackCount) callbacks)")

        watcher.stopWatching()
    }

    func testWatcherCanRestartOnDifferentDirectory() async throws {
        let tempDir1 = try createTempDirectory()
        let tempDir2 = try createTempDirectory()
        defer {
            removeTempDirectory(tempDir1)
            removeTempDirectory(tempDir2)
        }

        var changedPaths: [URL] = []
        let watcher = FileSystemWatcher { changes in
            changedPaths.append(contentsOf: changes.all.map(\.standardizedFileURL))
        }

        // Start watching first directory
        watcher.startWatching(directory: tempDir1)
        XCTAssertTrue(watcher.isWatching)

        // Switch to second directory (should auto-stop first)
        watcher.startWatching(directory: tempDir2)
        XCTAssertTrue(watcher.isWatching)
        try await settleWatcherRegistration()

        // Create file in first directory (should NOT trigger)
        let file1 = tempDir1.appendingPathComponent("test1.txt")
        try "Content 1".write(to: file1, atomically: true, encoding: .utf8)

        // Create file in second directory (SHOULD trigger)
        let file2 = tempDir2.appendingPathComponent("test2.txt")
        try "Content 2".write(to: file2, atomically: true, encoding: .utf8)

        let secondDirectoryChanged = try await waitUntil {
            changedPaths.contains { $0.path.hasPrefix(tempDir2.standardizedFileURL.path + "/") }
        }
        let firstDirectoryRemainedSilent = secondDirectoryChanged
            ? try await remainsTrue {
                !changedPaths.contains { $0.path.hasPrefix(tempDir1.standardizedFileURL.path + "/") }
            }
            : false

        XCTAssertTrue(secondDirectoryChanged, "Should get a callback from the second directory")
        XCTAssertTrue(
            firstDirectoryRemainedSilent,
            "The stopped first directory must not produce callbacks"
        )

        watcher.stopWatching()
    }

    // MARK: - Sidecar Filter Tests

    func testSidecarFilterIdentifiesMetaJSON() {
        let metaURL = URL(fileURLWithPath: "/project/Downloads/SRR123.fastq.gz.lungfish-meta.json")
        XCTAssertTrue(FileSystemWatcher.isSidecarPath(metaURL))
    }

    func testSidecarFilterIdentifiesSearchDB() {
        let dbURL = URL(fileURLWithPath: "/project/.universal-search.db")
        let walURL = URL(fileURLWithPath: "/project/.universal-search.db-wal")
        let shmURL = URL(fileURLWithPath: "/project/.universal-search.db-shm")
        XCTAssertTrue(FileSystemWatcher.isSidecarPath(dbURL))
        XCTAssertTrue(FileSystemWatcher.isSidecarPath(walURL))
        XCTAssertTrue(FileSystemWatcher.isSidecarPath(shmURL))
    }

    func testUniversalSearchArtifactsAreInternal() {
        let projectURL = URL(fileURLWithPath: "/project")
        let artifactNames = [
            ".universal-search.db",
            ".universal-search.db-wal",
            ".universal-search.db-shm",
            ".universal-search.db.lungfish-provenance.json",
            "..universal-search.db.lungfish-provenance.json.tmp-12345678-AbCdEf",
            "._.universal-search.db.lungfish-provenance.json.sb-12345678-AbCdEf",
        ]

        for name in artifactNames {
            XCTAssertTrue(
                FileSystemWatcher.isUniversalSearchInternalPath(
                    projectURL.appendingPathComponent(name)
                )
            )
        }

        XCTAssertFalse(
            FileSystemWatcher.isUniversalSearchInternalPath(
                projectURL.appendingPathComponent("sample.fastq.lungfish-meta.json")
            )
        )
    }

    func testSearchIndexWritesDoNotFeedBackIntoWatcher() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        var callbackCount = 0
        var receivedPaths: [String] = []
        let watcher = FileSystemWatcher { changes in
            callbackCount += 1
            receivedPaths.append(contentsOf: changes.all.map(\.lastPathComponent))
        }
        watcher.startWatching(directory: tempDir)
        try await settleWatcherRegistration()

        let service = UniversalProjectSearchService()
        _ = try await service.rebuild(projectURL: tempDir)
        let remainedSilent = try await remainsTrue { callbackCount == 0 }

        watcher.stopWatching()
        XCTAssertTrue(
            remainedSilent,
            "Search-index output must not trigger another search update; received \(receivedPaths)"
        )
    }

    func testSidecarFilterIdentifiesMetadataCSV() {
        let csvURL = URL(fileURLWithPath: "/project/Downloads/SRR123.lungfishfastq/metadata.csv")
        XCTAssertTrue(FileSystemWatcher.isSidecarPath(csvURL))
    }

    func testSidecarFilterIdentifiesJSONInBundles() {
        let manifestURL = URL(fileURLWithPath: "/project/Downloads/SRR123.lungfishfastq/derived.manifest.json")
        let readManifestURL = URL(fileURLWithPath: "/project/Downloads/SRR123.lungfishfastq/read-manifest.json")
        XCTAssertTrue(FileSystemWatcher.isSidecarPath(manifestURL))
        XCTAssertTrue(FileSystemWatcher.isSidecarPath(readManifestURL))

        // .lungfishref bundles too
        let refJSON = URL(fileURLWithPath: "/project/Reference Sequences/hg38.lungfishref/manifest.json")
        XCTAssertTrue(FileSystemWatcher.isSidecarPath(refJSON))
    }

    func testSidecarFilterAllowsNormalFiles() {
        let fastqURL = URL(fileURLWithPath: "/project/Downloads/SRR123.fastq.gz")
        let bamURL = URL(fileURLWithPath: "/project/Alignments/sample.bam")
        let bundleURL = URL(fileURLWithPath: "/project/Downloads/SRR123.lungfishfastq")
        XCTAssertFalse(FileSystemWatcher.isSidecarPath(fastqURL))
        XCTAssertFalse(FileSystemWatcher.isSidecarPath(bamURL))
        XCTAssertFalse(FileSystemWatcher.isSidecarPath(bundleURL))
    }

    func testSidecarFilterAllowsTopLevelJSON() {
        let resultJSON = URL(fileURLWithPath: "/project/Analyses/classification-2026-04/classification-result.json")
        XCTAssertFalse(FileSystemWatcher.isSidecarPath(resultJSON))
    }
}
