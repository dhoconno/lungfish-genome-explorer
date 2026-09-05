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

    // MARK: - Non-blocking setup (2026-09-02 launch hang)

    /// Counters a fake lifecycle records from whichever thread the watcher
    /// drives it on. FSEvents setup runs off the main actor now, so the
    /// bookkeeping has to be thread safe rather than MainActor-isolated.
    private final class LifecycleCounters: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func record(_ key: String) {
            lock.lock()
            counts[key, default: 0] += 1
            lock.unlock()
        }

        func count(_ key: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[key] ?? 0
        }
    }

    /// Builds a real (but never started) stream so the invalidate/release calls
    /// under test operate on a genuine FSEventStreamRef. Nonisolated because
    /// the lifecycle seam is driven from the watcher's setup queue.
    private nonisolated static func makeRealStream(for directory: URL) -> FSEventStreamRef {
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        return FSEventStreamCreate(
            nil,
            { _, _, _, _, _, _ in },
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            UInt32(kFSEventStreamCreateFlagUseCFTypes)
        )!
    }

    func testFailedStreamStartCleansUp() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        let counters = LifecycleCounters()
        let lifecycle = FileSystemWatcher.StreamLifecycle(
            create: { _, _, _, _ in Self.makeRealStream(for: tempDir) },
            setDispatchQueue: { _, _ in },
            start: { _ in false },
            stop: { _ in counters.record("stop") },
            invalidate: { stream in
                counters.record("invalidate")
                FSEventStreamInvalidate(stream)
            },
            release: { stream in
                counters.record("release")
                FSEventStreamRelease(stream)
            }
        )
        let watcher = FileSystemWatcher(
            onChange: { _ in },
            onRootChanged: nil,
            streamLifecycle: lifecycle
        )

        watcher.startWatching(directory: tempDir)
        await watcher.waitForPendingStreamSetup()

        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(counters.count("stop"), 0)
        XCTAssertEqual(counters.count("invalidate"), 1)
        XCTAssertEqual(counters.count("release"), 1)
    }

    func testNilStreamCreationLeavesWatcherInactive() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        let counters = LifecycleCounters()
        let lifecycle = FileSystemWatcher.StreamLifecycle(
            create: { _, _, _, _ in nil },
            setDispatchQueue: { _, _ in },
            start: { _ in counters.record("start"); return true },
            stop: { _ in },
            invalidate: { _ in },
            release: { _ in }
        )
        var unavailable: String?
        let watcher = FileSystemWatcher(onChange: { _ in }, onRootChanged: nil,
            onUnavailable: { unavailable = $0 }, streamLifecycle: lifecycle)

        watcher.startWatching(directory: tempDir)
        await watcher.waitForPendingStreamSetup()

        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(counters.count("start"), 0, "A nil stream must never be started")
        XCTAssertNotNil(unavailable, "A setup failure must be visible to subscribers")
    }

    func testStaleRootDeliveryCannotStopReplacementWatch() async throws {
        let first = try createTempDirectory()
        let second = try createTempDirectory()
        defer { removeTempDirectory(first); removeTempDirectory(second) }
        var rootChanges = 0
        let watcher = FileSystemWatcher(onChange: { _ in }, onRootChanged: { rootChanges += 1 })
        watcher.startWatching(directory: first)
        let oldGeneration = watcher.testingCurrentGeneration
        watcher.startWatching(directory: second)
        watcher.deliver(.rootChanged, generation: oldGeneration)
        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(rootChanges, 0)
        watcher.deliver(.rootChanged, generation: watcher.testingCurrentGeneration)
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(rootChanges, 1)
        await watcher.waitForPendingStreamSetup()
    }

    /// The launch hang: `FSEventStreamCreate` can wedge inside
    /// `watch_all_parents`, and it used to run on the main thread during
    /// `applicationDidFinishLaunching`, so no window was ever drawn. The caller
    /// must return promptly no matter how long creation takes.
    func testHangingStreamCreationDoesNotBlockCaller() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        let released = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let lifecycle = FileSystemWatcher.StreamLifecycle(
            create: { _, _, _, _ in
                entered.signal()
                released.wait()
                return Self.makeRealStream(for: tempDir)
            },
            setDispatchQueue: { _, _ in },
            start: { _ in true },
            stop: { _ in },
            invalidate: { FSEventStreamInvalidate($0) },
            release: { FSEventStreamRelease($0) }
        )
        let watcher = FileSystemWatcher(onChange: { _ in }, onRootChanged: nil, streamLifecycle: lifecycle)

        let started = Date()
        watcher.startWatching(directory: tempDir)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 1.0, "startWatching must not wait on FSEventStreamCreate")
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "Creation should have begun off the main thread")

        // The main actor stays responsive while creation is wedged.
        var mainActorRan = false
        let ticked = Task { @MainActor in mainActorRan = true }
        await ticked.value
        XCTAssertTrue(mainActorRan)

        released.signal()
        await watcher.waitForPendingStreamSetup()
        XCTAssertTrue(watcher.isWatching)
        watcher.stopWatching()
    }

    /// A `stopWatching()` that lands while creation is still in flight must
    /// tear the finished stream down instead of attaching it, otherwise the
    /// watcher leaks a live stream nobody can stop.
    func testStopDuringPendingSetupTearsDownTheLateStream() async throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }

        let counters = LifecycleCounters()
        let released = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let lifecycle = FileSystemWatcher.StreamLifecycle(
            create: { _, _, _, _ in
                entered.signal()
                released.wait()
                return Self.makeRealStream(for: tempDir)
            },
            setDispatchQueue: { _, _ in },
            start: { _ in counters.record("start"); return true },
            stop: { _ in counters.record("stop") },
            invalidate: { stream in
                counters.record("invalidate")
                FSEventStreamInvalidate(stream)
            },
            release: { stream in
                counters.record("release")
                FSEventStreamRelease(stream)
            }
        )
        let watcher = FileSystemWatcher(onChange: { _ in }, onRootChanged: nil, streamLifecycle: lifecycle)

        watcher.startWatching(directory: tempDir)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        watcher.stopWatching()

        released.signal()
        await watcher.waitForPendingStreamSetup()

        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(counters.count("stop"), 1, "The late stream must be stopped")
        XCTAssertEqual(counters.count("invalidate"), 1)
        XCTAssertEqual(counters.count("release"), 1)
    }

    /// Restarting on a second directory while the first setup is in flight must
    /// leave exactly one live stream: the second one.
    func testRestartDuringPendingSetupDiscardsTheSupersededStream() async throws {
        let tempDir1 = try createTempDirectory()
        let tempDir2 = try createTempDirectory()
        defer {
            removeTempDirectory(tempDir1)
            removeTempDirectory(tempDir2)
        }

        let counters = LifecycleCounters()
        let released = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let lifecycle = FileSystemWatcher.StreamLifecycle(
            create: { paths, _, _, _ in
                let watched = (paths as? [String])?.first ?? ""
                if watched == tempDir1.path {
                    entered.signal()
                    released.wait()
                }
                return Self.makeRealStream(for: tempDir2)
            },
            setDispatchQueue: { _, _ in },
            start: { _ in counters.record("start"); return true },
            stop: { _ in counters.record("stop") },
            invalidate: { stream in
                counters.record("invalidate")
                FSEventStreamInvalidate(stream)
            },
            release: { stream in
                counters.record("release")
                FSEventStreamRelease(stream)
            }
        )
        let watcher = FileSystemWatcher(onChange: { _ in }, onRootChanged: nil, streamLifecycle: lifecycle)

        watcher.startWatching(directory: tempDir1)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        watcher.startWatching(directory: tempDir2)
        released.signal()
        await watcher.waitForPendingStreamSetup()

        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(counters.count("start"), 2, "Both streams start; only the current one is kept")
        XCTAssertEqual(counters.count("stop"), 1, "The superseded stream is torn down")
        XCTAssertEqual(counters.count("release"), 1)

        watcher.stopWatching()
        XCTAssertEqual(counters.count("stop"), 2)
        XCTAssertEqual(counters.count("release"), 2)
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

    // MARK: - Stream policy (2026-08-22 fseventsd OOM)

    func testNativeVolumesGetPerFileEventsAndForeignVolumesDoNot() {
        XCTAssertEqual(FileSystemWatcher.StreamPolicy.policy(forVolumeTypeName: "apfs"), .nativeVolume)
        XCTAssertEqual(FileSystemWatcher.StreamPolicy.policy(forVolumeTypeName: "HFS"), .nativeVolume)
        XCTAssertEqual(FileSystemWatcher.StreamPolicy.policy(forVolumeTypeName: "exfat"), .foreignVolume)
        XCTAssertEqual(FileSystemWatcher.StreamPolicy.policy(forVolumeTypeName: "smbfs"), .foreignVolume)
        XCTAssertEqual(FileSystemWatcher.StreamPolicy.policy(forVolumeTypeName: nil), .foreignVolume)
        XCTAssertFalse(FileSystemWatcher.StreamPolicy.foreignVolume.perFileEvents)
        XCTAssertGreaterThan(FileSystemWatcher.StreamPolicy.foreignVolume.latency, FileSystemWatcher.StreamPolicy.nativeVolume.latency)
    }

    @MainActor
    func testWatcherOnThisVolumeReportsItsPolicy() throws {
        let tempDir = try createTempDirectory()
        defer { removeTempDirectory(tempDir) }
        let watcher = FileSystemWatcher(onChange: { _ in })
        watcher.startWatching(directory: tempDir)
        defer { watcher.stopWatching() }
        let expected = FileSystemWatcher.StreamPolicy.policy(
            forVolumeTypeName: FileSystemWatcher.volumeTypeName(of: tempDir)
        )
        XCTAssertEqual(watcher.streamPolicy, expected)
    }

    func testBurstOfChangesCoalescesIntoOneFullReload() {
        let root = "/proj.lungfish"
        let paths = (0..<600).map { "\(root)/Analyses/run/sample\($0)/classification.kraken" }
        let delivery = FileSystemWatcher.classify(
            paths: paths,
            flags: Array(repeating: 0, count: paths.count),
            watchedRootPath: root,
            policy: .foreignVolume
        )
        XCTAssertEqual(delivery, .fullReload(reason: "burst of 600 changes"))

        let small = FileSystemWatcher.classify(
            paths: Array(paths.prefix(3)),
            flags: [0, 0, 0],
            watchedRootPath: root,
            policy: .foreignVolume
        )
        guard case .paths(let changed) = small else { return XCTFail("expected per-path delivery, got \(small)") }
        XCTAssertEqual(changed.all.count, 3)
    }

    func testClassifyHonoursRootChangedAndMustScanFlags() {
        XCTAssertEqual(
            FileSystemWatcher.classify(paths: ["/p"], flags: [kFSEventStreamEventFlagRootChanged], watchedRootPath: "/p", policy: .nativeVolume),
            .rootChanged
        )
        XCTAssertEqual(
            FileSystemWatcher.classify(paths: ["/p/x"], flags: [kFSEventStreamEventFlagMustScanSubDirs], watchedRootPath: "/p", policy: .nativeVolume),
            .fullReload(reason: "MustScanSubDirs flag")
        )
        XCTAssertEqual(
            FileSystemWatcher.classify(paths: ["/p"], flags: [0], watchedRootPath: "/p", policy: .nativeVolume),
            .none
        )
    }

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
