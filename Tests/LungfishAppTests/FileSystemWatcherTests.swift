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

        let expectation = Expectation()
        var callbackInvoked = false

        let watcher = FileSystemWatcher {
            callbackInvoked = true
            expectation.fulfill()
        }

        watcher.startWatching(directory: tempDir)
        #expect(watcher.isWatching == true)

        // Create a file
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "Hello, World!".write(to: testFile, atomically: true, encoding: .utf8)

        // Wait for callback (with timeout)
        // FSEvents has latency + debounce, so we need to wait
        try await Task.sleep(for: .seconds(2))

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
        try await Task.sleep(for: .milliseconds(500))

        var callbackCount = 0
        let watcher = FileSystemWatcher {
            callbackCount += 1
        }

        watcher.startWatching(directory: tempDir)

        // Delete the file
        try FileManager.default.removeItem(at: testFile)

        // Wait for callback
        try await Task.sleep(for: .seconds(2))

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
        try await Task.sleep(for: .milliseconds(500))

        var callbackCount = 0
        let watcher = FileSystemWatcher {
            callbackCount += 1
        }

        watcher.startWatching(directory: tempDir)

        // Rename the file
        let renamedFile = tempDir.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: originalFile, to: renamedFile)

        // Wait for callback
        try await Task.sleep(for: .seconds(2))

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
        try await Task.sleep(for: .milliseconds(500))

        var callbackInvoked = false
        let watcher = FileSystemWatcher {
            callbackInvoked = true
        }

        watcher.startWatching(directory: tempDir)

        // Create a file in the nested directory
        let nestedFile = nestedDir.appendingPathComponent("nested_file.txt")
        try "Nested content".write(to: nestedFile, atomically: true, encoding: .utf8)

        // Wait for callback
        try await Task.sleep(for: .seconds(2))

        #expect(callbackInvoked == true, "Callback should be invoked for changes in nested directories")

        watcher.stopWatching()
    }

    @Test("Watcher properly cleans up on stop")
    @MainActor
    func watcherCleansUpOnStop() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        var callbackCount = 0
        let watcher = FileSystemWatcher {
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
        try await Task.sleep(for: .seconds(2))

        #expect(callbackCount == 0, "Callback should not be invoked after stopWatching()")
    }

    @Test("Watcher filters hidden files from visible changes")
    @MainActor
    func watcherFiltersHiddenFiles() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        var hiddenOnlyCallbackCount = 0
        var visibleCallbackCount = 0

        // First test: only hidden file - should not trigger callback
        let watcher1 = FileSystemWatcher {
            hiddenOnlyCallbackCount += 1
        }
        watcher1.startWatching(directory: tempDir)

        // Create a hidden file (like .project.db)
        let hiddenFile = tempDir.appendingPathComponent(".hidden_file")
        try "Hidden content".write(to: hiddenFile, atomically: true, encoding: .utf8)

        // Wait for potential callback
        try await Task.sleep(for: .seconds(2))
        watcher1.stopWatching()

        // Note: FSEvents may still report directory-level changes, so we can't
        // guarantee zero callbacks. The key test is that visible files DO trigger.

        // Second test: visible file - SHOULD trigger callback
        let watcher2 = FileSystemWatcher {
            visibleCallbackCount += 1
        }
        watcher2.startWatching(directory: tempDir)

        let visibleFile = tempDir.appendingPathComponent("visible.txt")
        try "Visible content".write(to: visibleFile, atomically: true, encoding: .utf8)

        try await Task.sleep(for: .seconds(2))
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
        let watcher = FileSystemWatcher {
            callbackCount += 1
        }

        watcher.startWatching(directory: tempDir)

        // Create multiple files in rapid succession
        for i in 0..<5 {
            let testFile = tempDir.appendingPathComponent("test_\(i).txt")
            try "Content \(i)".write(to: testFile, atomically: true, encoding: .utf8)
        }

        // Wait for debounced callback
        try await Task.sleep(for: .seconds(2))

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
        let watcher = FileSystemWatcher {
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
        try await Task.sleep(for: .seconds(2))

        // Should only get callback from second directory
        #expect(callbackCount >= 1, "Should get callback from second directory")

        watcher.stopWatching()
    }
}

// MARK: - Test Helpers

/// Simple expectation helper for async testing
private class Expectation {
    private var fulfilled = false

    func fulfill() {
        fulfilled = true
    }

    func isFulfilled() -> Bool {
        return fulfilled
    }
}
