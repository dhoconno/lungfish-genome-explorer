// FASTQOperationDialogStateBarcodeScanOffMainTests.swift - Regression tests proving the
// recursive project directory scan behind `projectBarcodeDefinitionCandidates` runs off the
// main actor and is discarded when superseded, with identical results to the old synchronous
// scan. See F8.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

/// Thread-safe capture box for the `barcodeDefinitionScanThreadingProbe` hook. The probe
/// closure is `@Sendable` and fires from whatever thread the scan actually runs on; this box
/// lets the (MainActor) test method read the captured value afterward.
private final class ThreadObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _wasMainThread: Bool?
    private var _fired = false

    func record() {
        let isMain = Thread.isMainThread
        lock.lock()
        _wasMainThread = isMain
        _fired = true
        lock.unlock()
    }

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _fired
    }

    var wasMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _wasMainThread
    }
}

/// A plain semaphore-based gate for coordinating the (synchronous, `@Sendable`) threading
/// probe closure with the test method. `DispatchSemaphore` is used instead of an actor
/// because the probe closure itself is synchronous and deliberately blocks the detached
/// scan's own OS thread while holding it open -- that thread is not part of the constrained
/// Swift concurrency cooperative pool (`Task.detached` work still runs on real
/// `libdispatch`-backed worker threads), so blocking it directly (`blockingWait()`) is safe.
/// The *test method*, however, runs on a cooperative-pool thread, so its side (`wait()`) must
/// not call `DispatchSemaphore.wait()` directly -- doing so risks starving the small,
/// fixed-size pool if the detached task ever needed a pool slot to make progress. `wait()`
/// instead hops the blocking wait onto a plain `Thread`, keeping the cooperative pool free.
private final class ScanGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    /// Async, cooperative-pool-safe wait for use from test methods.
    func wait() async {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                self.semaphore.wait()
                continuation.resume()
            }
            thread.start()
        }
    }

    /// Synchronous wait for use only from inside the threading-probe closure, which already
    /// runs on a real (non-cooperative-pool) worker thread.
    func blockingWait() {
        semaphore.wait()
    }

    func open() {
        semaphore.signal()
    }
}

/// Thread-safe counter for the number of times a `@Sendable` probe closure has fired.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Increments the count and returns the new value.
    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

@MainActor
final class FASTQOperationDialogStateBarcodeScanOffMainTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBarcodeScanOffMainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        FASTQOperationDialogState.barcodeDefinitionScanThreadingProbe = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - Construction no longer scans synchronously

    /// `init` must not populate `projectBarcodeDefinitionCandidates` synchronously: the
    /// recursive directory walk only happens once `refreshProjectBarcodeDefinitionCandidates()`
    /// is awaited (mirroring how the dialog's `.task` triggers it after presentation).
    func testInitDoesNotPopulateCandidatesSynchronously() throws {
        try write("samples.csv", contents: "id,barcode\n1,AAAA\n", in: tempRoot)

        let state = FASTQOperationDialogState(
            initialCategory: .demultiplexing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
            projectURL: tempRoot
        )

        XCTAssertEqual(state.projectBarcodeDefinitionCandidates, [])
    }

    // MARK: - Threading regression

    /// The heavy recursive scan, driven from an actual `@MainActor` context (as the dialog's
    /// `.task` does), must not run on the main thread. `Task.detached` makes this an
    /// unconditional structural guarantee.
    func testScanRunsOffMainThreadWhenCalledFromMainActor() async throws {
        try write("samples.csv", contents: "id,barcode\n1,AAAA\n", in: tempRoot)
        let observation = ThreadObservationBox()
        FASTQOperationDialogState.barcodeDefinitionScanThreadingProbe = { observation.record() }

        let state = FASTQOperationDialogState(
            initialCategory: .demultiplexing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
            projectURL: tempRoot
        )
        await state.refreshProjectBarcodeDefinitionCandidates()

        XCTAssertTrue(observation.fired, "threadingProbe never fired -- test is not exercising the real code path")
        XCTAssertEqual(observation.wasMainThread, false, "barcode-definition scan ran on the main thread")
        XCTAssertEqual(state.projectBarcodeDefinitionCandidates.count, 1)
    }

    // MARK: - Result parity

    /// The async scan must produce the exact same candidate set (and ordering) as the original
    /// synchronous implementation: nested directories, mixed extensions, bundle/package
    /// exclusion, and hidden-file skipping all behave identically.
    func testAsyncScanResultMatchesDirectStaticScan() async throws {
        try write("root.csv", contents: "id,barcode\n1,AAAA\n", in: tempRoot)
        let nested = tempRoot.appendingPathComponent("Imports/batch1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("nested.tsv", contents: "id\tbarcode\n1\tAAAA\n", in: nested)
        try write("notes.txt", contents: "not a barcode file but matches extension allowlist", in: tempRoot)
        try write("ignored.json", contents: "{}", in: tempRoot)
        try write(".hidden.csv", contents: "id,barcode\n1,AAAA\n", in: tempRoot)

        // A .lungfishfastq "bundle" directory should be skipped entirely, even though it
        // contains a .csv file that would otherwise match.
        let bundleDir = tempRoot.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try write("manifest.json", contents: "{\"format\":\"fastq\"}", in: bundleDir)
        try write("inner.csv", contents: "id,barcode\n1,AAAA\n", in: bundleDir)

        let expected = FASTQOperationDialogState.directScanForTesting(in: tempRoot)
        XCTAssertFalse(expected.isEmpty, "fixture setup should produce at least one candidate")

        let state = FASTQOperationDialogState(
            initialCategory: .demultiplexing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
            projectURL: tempRoot
        )
        await state.refreshProjectBarcodeDefinitionCandidates()

        XCTAssertEqual(state.projectBarcodeDefinitionCandidates, expected)
    }

    // MARK: - Stale-result discard (deterministic, gated double-invoke)

    /// Firing a second `refreshProjectBarcodeDefinitionCandidates()` call while the first is
    /// still in flight must let the second (newer) call win, even if the first call's scan
    /// happens to finish (and try to apply its result) afterward. The first call's `Task`
    /// itself is held open on a gate -- via the threading probe, which fires before the
    /// filesystem walk starts -- until the test has explicitly let the second call run to
    /// completion and apply its result, so the ordering is deterministic rather than
    /// timing-dependent. The two calls target *different* project directories (rather than
    /// mutating one directory mid-flight, which the gate placement makes unreliable to
    /// distinguish) so their results are guaranteed to differ and a "last write wins by
    /// accident" false pass is not possible: if the guard is removed, the first (stale)
    /// call's directory-A result overwrites the second call's already-applied directory-B
    /// result once released, which this test's final assertion catches.
    func testStaleInFlightScanIsDiscardedInFavorOfNewerScan() async throws {
        let projectA = tempRoot.appendingPathComponent("ProjectA", isDirectory: true)
        let projectB = tempRoot.appendingPathComponent("ProjectB", isDirectory: true)
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)
        try write("a1.csv", contents: "id,barcode\n1,AAAA\n", in: projectA)
        try write("b1.csv", contents: "id,barcode\n1,AAAA\n", in: projectB)
        try write("b2.tsv", contents: "id\tbarcode\n1\tAAAA\n", in: projectB)

        let expectedA = FASTQOperationDialogState.directScanForTesting(in: projectA)
        let expectedB = FASTQOperationDialogState.directScanForTesting(in: projectB)
        XCTAssertEqual(expectedA.count, 1)
        XCTAssertEqual(expectedB.count, 2)

        let state = FASTQOperationDialogState(
            initialCategory: .demultiplexing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
            projectURL: projectA
        )

        let firstScanStarted = ScanGate()
        let releaseFirstScan = ScanGate()
        let probeCallCount = CallCounter()

        FASTQOperationDialogState.barcodeDefinitionScanThreadingProbe = { [firstScanStarted, releaseFirstScan, probeCallCount] in
            if probeCallCount.increment() == 1 {
                // First (stale) scan against projectA: announce it has started, then block
                // synchronously (this closure runs on the detached scan's own thread, before
                // the filesystem walk begins) until the test explicitly releases it -- by
                // which point the second scan against projectB will have both started and
                // finished and applied its result.
                firstScanStarted.open()
                releaseFirstScan.blockingWait()
            }
        }

        // Start the first (soon-to-be-stale) scan but don't await it yet.
        let firstTask = Task { await state.refreshProjectBarcodeDefinitionCandidates() }
        await firstScanStarted.wait()

        // Second (superseding) scan: retarget to projectB, run to completion, apply result.
        state.projectURL = projectB
        await state.refreshProjectBarcodeDefinitionCandidates()
        let afterSecond = state.projectBarcodeDefinitionCandidates
        XCTAssertEqual(afterSecond, expectedB, "second scan should observe projectB's files")

        // Now release the first scan and let it finish. Its stale projectA result must NOT
        // overwrite the second scan's already-applied projectB result.
        releaseFirstScan.open()
        await firstTask.value

        XCTAssertEqual(
            state.projectBarcodeDefinitionCandidates,
            afterSecond,
            "a stale in-flight scan overwrote the result of a newer scan"
        )
        XCTAssertNotEqual(
            state.projectBarcodeDefinitionCandidates,
            expectedA,
            "the stale scan's result leaked through despite being superseded"
        )
    }

    // MARK: - Helpers

    private func write(_ name: String, contents: String, in directory: URL) throws {
        try contents.write(
            to: directory.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }
}
