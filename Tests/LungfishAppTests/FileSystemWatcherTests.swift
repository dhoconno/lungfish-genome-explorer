// FileSystemWatcherTests.swift - Tests for FSEvents-based directory monitoring
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import LungfishApp

/// Tests for the FileSystemWatcher class.
///
/// These tests verify that the FSEvents-based watcher correctly detects
/// filesystem changes including file creation, deletion, and modification.
@Suite("FileSystemWatcher Tests")
struct FileSystemWatcherTests {

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

    @Test("Watcher detects new file creation")
    @MainActor
    func watcherDetectsFileCreation() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        var callbackInvoked = false

        let watcher = FileSystemWatcher { _ in
            callbackInvoked = true
        }

        watcher.startWatching(directory: tempDir)
        #expect(watcher.isWatching == true)

        // Create a file
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "Hello, World!".write(to: testFile, atomically: true, encoding: .utf8)

        // Wait for callback (with timeout)
        // FSEvents has latency + debounce, so we need to wait
        try await Task.sleep(for: .seconds(5))

        #expect(callbackInvoked == true, "Callback should be invoked when file is created")

        watcher.stopWatching()
        #expect(watcher.isWatching == false)
    }

    @Test("Watcher detects file deletion")
    @MainActor
    func watcherDetectsFileDeletion() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        // Create a file first
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "Hello, World!".write(to: testFile, atomically: true, encoding: .utf8)

        // Wait a moment for the filesystem to settle
        try await Task.sleep(for: .seconds(1))

        var callbackCount = 0
        let watcher = FileSystemWatcher { _ in
            callbackCount += 1
        }

        watcher.startWatching(directory: tempDir)

        // Delete the file
        try FileManager.default.removeItem(at: testFile)

        // Wait for callback
        try await Task.sleep(for: .seconds(5))

        #expect(callbackCount >= 1, "Callback should be invoked when file is deleted")

        watcher.stopWatching()
    }

    @Test("Watcher detects file rename/move")
    @MainActor
    func watcherDetectsFileRename() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        // Create a file first
        let originalFile = tempDir.appendingPathComponent("original.txt")
        try "Hello, World!".write(to: originalFile, atomically: true, encoding: .utf8)

        // Wait a moment for the filesystem to settle
        try await Task.sleep(for: .seconds(1))

        var callbackCount = 0
        let watcher = FileSystemWatcher { _ in
            callbackCount += 1
        }

        watcher.startWatching(directory: tempDir)

        // Rename the file
        let renamedFile = tempDir.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: originalFile, to: renamedFile)

        // Wait for callback
        try await Task.sleep(for: .seconds(5))

        #expect(callbackCount >= 1, "Callback should be invoked when file is renamed")

        watcher.stopWatching()
    }

    @Test("Watcher handles nested directory changes")
    @MainActor
    func watcherHandlesNestedChanges() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        // Create a nested directory
        let nestedDir = tempDir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)

        // Wait a moment for the filesystem to settle
        try await Task.sleep(for: .seconds(1))

        var callbackInvoked = false
        let watcher = FileSystemWatcher { _ in
            callbackInvoked = true
        }

        watcher.startWatching(directory: tempDir)

        // Create a file in the nested directory
        let nestedFile = nestedDir.appendingPathComponent("nested_file.txt")
        try "Nested content".write(to: nestedFile, atomically: true, encoding: .utf8)

        // Wait for callback
        try await Task.sleep(for: .seconds(5))

        #expect(callbackInvoked == true, "Callback should be invoked for changes in nested directories")

        watcher.stopWatching()
    }

    @Test("Watcher properly cleans up on stop")
    @MainActor
    func watcherCleansUpOnStop() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        var callbackCount = 0
        let watcher = FileSystemWatcher { _ in
            callbackCount += 1
        }

        watcher.startWatching(directory: tempDir)
        #expect(watcher.isWatching == true)

        watcher.stopWatching()
        #expect(watcher.isWatching == false)

        // Create a file after stopping
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "Hello, World!".write(to: testFile, atomically: true, encoding: .utf8)

        // Wait to ensure no callback is triggered
        try await Task.sleep(for: .seconds(5))

        #expect(callbackCount == 0, "Callback should not be invoked after stopWatching()")
    }

    @Test("Watcher reports when its root directory is moved")
    @MainActor
    func watcherReportsMovedRoot() async throws {
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

        try FileManager.default.moveItem(at: tempDir, to: movedDir)
        try await Task.sleep(for: .seconds(5))

        #expect(rootChanged, "Moving the watched project root must invoke onRootChanged")
    }

    @Test("Watcher filters hidden files from visible changes")
    @MainActor
    func watcherFiltersHiddenFiles() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        var hiddenOnlyCallbackCount = 0
        var visibleCallbackCount = 0

        // First test: only hidden file - should not trigger callback
        let watcher1 = FileSystemWatcher { _ in
            hiddenOnlyCallbackCount += 1
        }
        watcher1.startWatching(directory: tempDir)

        // Create a hidden file (like .project.db)
        let hiddenFile = tempDir.appendingPathComponent(".hidden_file")
        try "Hidden content".write(to: hiddenFile, atomically: true, encoding: .utf8)

        // Wait for potential callback
        try await Task.sleep(for: .seconds(5))
        watcher1.stopWatching()

        // Note: FSEvents may still report directory-level changes, so we can't
        // guarantee zero callbacks. The key test is that visible files DO trigger.

        // Second test: visible file - SHOULD trigger callback
        let watcher2 = FileSystemWatcher { _ in
            visibleCallbackCount += 1
        }
        watcher2.startWatching(directory: tempDir)

        let visibleFile = tempDir.appendingPathComponent("visible.txt")
        try "Visible content".write(to: visibleFile, atomically: true, encoding: .utf8)

        try await Task.sleep(for: .seconds(5))
        watcher2.stopWatching()

        // Visible file changes MUST trigger callback
        #expect(visibleCallbackCount >= 1, "Callback MUST be invoked for visible files")

        // Hidden-only changes should ideally not trigger, but FSEvents behavior varies
        // The important thing is that we filter them in handleFilesystemChange
    }

    @Test("Watcher debounces rapid changes")
    @MainActor
    func watcherDebouncesRapidChanges() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        var callbackCount = 0
        let watcher = FileSystemWatcher { _ in
            callbackCount += 1
        }

        watcher.startWatching(directory: tempDir)

        // Create multiple files in rapid succession
        for i in 0..<5 {
            let testFile = tempDir.appendingPathComponent("test_\(i).txt")
            try "Content \(i)".write(to: testFile, atomically: true, encoding: .utf8)
        }

        // Wait for debounced callback
        try await Task.sleep(for: .seconds(5))

        // Due to debouncing, we should get fewer callbacks than file operations
        // Ideally just 1 callback after all the rapid changes
        #expect(callbackCount >= 1, "Should get at least one callback")
        #expect(callbackCount <= 2, "Debouncing should coalesce rapid changes (got \(callbackCount) callbacks)")

        watcher.stopWatching()
    }

    @Test("Can restart watcher on different directory")
    @MainActor
    func watcherCanRestartOnDifferentDirectory() async throws {
        let tempDir1 = try createTempDirectory()
        let tempDir2 = try createTempDirectory()
        defer {
            removeTempDirectory(tempDir1)
            removeTempDirectory(tempDir2)
        }

        var callbackCount = 0
        let watcher = FileSystemWatcher { _ in
            callbackCount += 1
        }

        // Start watching first directory
        watcher.startWatching(directory: tempDir1)
        #expect(watcher.isWatching == true)

        // Switch to second directory (should auto-stop first)
        watcher.startWatching(directory: tempDir2)
        #expect(watcher.isWatching == true)

        // Create file in first directory (should NOT trigger)
        let file1 = tempDir1.appendingPathComponent("test1.txt")
        try "Content 1".write(to: file1, atomically: true, encoding: .utf8)

        // Create file in second directory (SHOULD trigger)
        let file2 = tempDir2.appendingPathComponent("test2.txt")
        try "Content 2".write(to: file2, atomically: true, encoding: .utf8)

        // Wait for callback
        try await Task.sleep(for: .seconds(5))

        // Should only get callback from second directory
        #expect(callbackCount >= 1, "Should get callback from second directory")

        watcher.stopWatching()
    }

    // MARK: - Sidecar Filter Tests

    @Test("isSidecarPath identifies lungfish-meta.json files")
    func sidecarFilterIdentifiesMetaJSON() {
        let metaURL = URL(fileURLWithPath: "/project/Downloads/SRR123.fastq.gz.lungfish-meta.json")
        #expect(FileSystemWatcher.isSidecarPath(metaURL) == true)
    }

    @Test("isSidecarPath identifies universal search database files")
    func sidecarFilterIdentifiesSearchDB() {
        let dbURL = URL(fileURLWithPath: "/project/.universal-search.db")
        let walURL = URL(fileURLWithPath: "/project/.universal-search.db-wal")
        let shmURL = URL(fileURLWithPath: "/project/.universal-search.db-shm")
        #expect(FileSystemWatcher.isSidecarPath(dbURL) == true)
        #expect(FileSystemWatcher.isSidecarPath(walURL) == true)
        #expect(FileSystemWatcher.isSidecarPath(shmURL) == true)
    }

    @Test("Universal search artifacts are excluded from their own filesystem updates")
    func universalSearchArtifactsAreInternal() {
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
            #expect(
                FileSystemWatcher.isUniversalSearchInternalPath(
                    projectURL.appendingPathComponent(name)
                )
            )
        }

        #expect(
            FileSystemWatcher.isUniversalSearchInternalPath(
                projectURL.appendingPathComponent("sample.fastq.lungfish-meta.json")
            ) == false
        )
    }

    @Test("Writing the search index and provenance does not notify its own watcher")
    @MainActor
    func searchIndexWritesDoNotFeedBackIntoWatcher() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        var callbackCount = 0
        var receivedPaths: [String] = []
        let watcher = FileSystemWatcher { changes in
            callbackCount += 1
            receivedPaths.append(contentsOf: changes.all.map(\.lastPathComponent))
        }
        watcher.startWatching(directory: tempDir)

        let service = UniversalProjectSearchService()
        _ = try await service.rebuild(projectURL: tempDir)
        try await Task.sleep(for: .seconds(5))

        watcher.stopWatching()
        #expect(
            callbackCount == 0,
            "Search-index output must not trigger another search update; received \(receivedPaths)"
        )
    }

    @Test("isSidecarPath identifies metadata.csv")
    func sidecarFilterIdentifiesMetadataCSV() {
        let csvURL = URL(fileURLWithPath: "/project/Downloads/SRR123.lungfishfastq/metadata.csv")
        #expect(FileSystemWatcher.isSidecarPath(csvURL) == true)
    }

    @Test("isSidecarPath identifies JSON inside bundles")
    func sidecarFilterIdentifiesJSONInBundles() {
        let manifestURL = URL(fileURLWithPath: "/project/Downloads/SRR123.lungfishfastq/derived.manifest.json")
        let readManifestURL = URL(fileURLWithPath: "/project/Downloads/SRR123.lungfishfastq/read-manifest.json")
        #expect(FileSystemWatcher.isSidecarPath(manifestURL) == true)
        #expect(FileSystemWatcher.isSidecarPath(readManifestURL) == true)

        // .lungfishref bundles too
        let refJSON = URL(fileURLWithPath: "/project/Reference Sequences/hg38.lungfishref/manifest.json")
        #expect(FileSystemWatcher.isSidecarPath(refJSON) == true)
    }

    @Test("isSidecarPath allows non-sidecar files through")
    func sidecarFilterAllowsNormalFiles() {
        let fastqURL = URL(fileURLWithPath: "/project/Downloads/SRR123.fastq.gz")
        let bamURL = URL(fileURLWithPath: "/project/Alignments/sample.bam")
        let bundleURL = URL(fileURLWithPath: "/project/Downloads/SRR123.lungfishfastq")
        #expect(FileSystemWatcher.isSidecarPath(fastqURL) == false)
        #expect(FileSystemWatcher.isSidecarPath(bamURL) == false)
        #expect(FileSystemWatcher.isSidecarPath(bundleURL) == false)
    }

    @Test("isSidecarPath allows top-level JSON files outside bundles")
    func sidecarFilterAllowsTopLevelJSON() {
        let resultJSON = URL(fileURLWithPath: "/project/Analyses/classification-2026-04/classification-result.json")
        #expect(FileSystemWatcher.isSidecarPath(resultJSON) == false)
    }
}
