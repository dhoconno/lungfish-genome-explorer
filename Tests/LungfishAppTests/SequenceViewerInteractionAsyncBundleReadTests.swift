// SequenceViewerInteractionAsyncBundleReadTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Regression tests for F4: fetchAnnotationBasesAsync / selectedFASTAOperationInput must not
// perform bundle file I/O synchronously on the main thread when invoked from the real
// @MainActor call sites (context-menu @objc handlers, NotificationCenter handlers).
//
// Two things are asserted:
//  1. Result parity — the async path returns byte-identical output to what the old
//     synchronous `fetchSequenceSync`-based implementation produced, verified against a
//     tiny on-disk reference bundle fixture.
//  2. Threading — the heavy bundle-I/O body actually runs off the main thread when awaited
//     from a real @MainActor caller. This is mutation-verified (see the note at the bottom):
//     removing the `Task.detached` hop and simply awaiting `bundle.fetchSequence` directly
//     was checked to make this test's own diagnostic fail before the fix was written, mirroring
//     the sibling B3/F14 finding's investigation.

import AppKit
import LungfishCore
import LungfishIO
import XCTest
@testable import LungfishApp

@MainActor
final class SequenceViewerInteractionAsyncBundleReadTests: XCTestCase {
    nonisolated(unsafe) private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-async-bundle-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SequenceViewerView.fastaOperationThreadingProbe = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    // MARK: - Result parity

    func testFetchAnnotationBasesAsyncMatchesSyncFetchForSingleIntervalAnnotation() async throws {
        let bundleURL = try makeReferenceBundle(chromosomeName: "MN908947", sequence: "AAACCCGGGTTT")
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        viewer.setReferenceBundle(bundle)

        let annotation = SequenceAnnotation(
            type: .gene,
            name: "test-gene",
            chromosome: "MN908947",
            start: 3,
            end: 9
        )

        // Ground truth computed via the pre-fix synchronous API directly, independent of the
        // production code path under test.
        let expected = try bundle.fetchSequenceSync(
            region: GenomicRegion(chromosome: "MN908947", start: 3, end: 9)
        )

        let actual = await viewer.fetchAnnotationBasesAsync(annotation)

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual, "CCCGGG")
    }

    func testFetchAnnotationBasesAsyncConcatenatesMultipleIntervalsInOrder() async throws {
        let bundleURL = try makeReferenceBundle(chromosomeName: "MN908947", sequence: "AAACCCGGGTTT")
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        viewer.setReferenceBundle(bundle)

        let annotation = SequenceAnnotation(
            type: .gene,
            name: "split-gene",
            chromosome: "MN908947",
            intervals: [
                AnnotationInterval(start: 0, end: 3),
                AnnotationInterval(start: 9, end: 12)
            ]
        )

        var expected = ""
        for interval in annotation.intervals {
            expected += try bundle.fetchSequenceSync(
                region: GenomicRegion(chromosome: "MN908947", start: interval.start, end: interval.end)
            )
        }

        let actual = await viewer.fetchAnnotationBasesAsync(annotation)

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual, "AAATTT")
    }

    func testFetchAnnotationBasesAsyncReturnsNilWhenNoBundleOrSequenceIsLoaded() async {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let annotation = SequenceAnnotation(type: .gene, name: "orphan", start: 0, end: 5)

        let result = await viewer.fetchAnnotationBasesAsync(annotation)

        XCTAssertNil(result)
    }

    func testSelectedFASTAOperationInputAsyncMatchesSyncFetchForBundleBackedSelection() async throws {
        let bundleURL = try makeReferenceBundle(chromosomeName: "MN908947", sequence: "AAACCCGGGTTT")
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let viewerController = ViewerViewController()
        viewerController.loadView()
        viewerController.referenceFrame = ReferenceFrame(
            chromosome: "MN908947.3",
            start: 3,
            end: 9,
            pixelWidth: 400,
            sequenceLength: 12
        )
        viewerController.viewerView.setReferenceBundle(bundle)
        viewerController.viewerView.selectVisibleRegion()

        let expectedBases = try bundle.fetchSequenceSync(
            region: GenomicRegion(chromosome: "MN908947", start: 3, end: 9)
        )

        let input = try await viewerController.viewerView.selectedFASTAOperationInput()

        XCTAssertEqual(input.suggestedName, "MN908947_4_9")
        XCTAssertEqual(input.records, [">MN908947_4_9\n\(expectedBases)\n"])
    }

    // MARK: - Threading (the CRITICAL-class regression from the sibling B3/F14 review)

    /// Proves the bundle-I/O body inside `fetchAnnotationBasesAsync` actually executes off the
    /// main thread when awaited from a real `@MainActor` caller — not merely that the function
    /// is declared `async`. `ReferenceBundle.fetchSequence(region:)` has no internal `await`
    /// before its synchronous file I/O, so a nonisolated `async` call with no structural hop
    /// can legally inherit the caller's (main) thread; only `Task.detached` guarantees otherwise.
    func testFetchAnnotationBasesAsyncRunsBundleIOOffMainThreadWhenCalledFromMainActor() async throws {
        let bundleURL = try makeReferenceBundle(chromosomeName: "MN908947", sequence: "AAACCCGGGTTT")
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        viewer.setReferenceBundle(bundle)

        let annotation = SequenceAnnotation(
            type: .gene,
            name: "test-gene",
            chromosome: "MN908947",
            start: 3,
            end: 9
        )

        let observation = ThreadObservationBox()
        SequenceViewerView.fastaOperationThreadingProbe = {
            observation.record(isMainThread: Thread.isMainThread)
        }

        // This test method is itself @MainActor-isolated (class-level @MainActor), matching
        // every real production call site (@objc menu handlers / NotificationCenter handlers
        // all run on the main thread).
        XCTAssertTrue(Thread.isMainThread, "Precondition: test body must start on the main thread")
        _ = await viewer.fetchAnnotationBasesAsync(annotation)

        XCTAssertTrue(observation.fired, "Threading probe never fired — heavy-work path was not exercised")
        XCTAssertFalse(observation.wasMainThread, "fetchAnnotationBasesAsync ran its bundle I/O on the main thread")
    }

    func testSelectedFASTAOperationInputRunsBundleIOOffMainThreadWhenCalledFromMainActor() async throws {
        let bundleURL = try makeReferenceBundle(chromosomeName: "MN908947", sequence: "AAACCCGGGTTT")
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let viewerController = ViewerViewController()
        viewerController.loadView()
        viewerController.referenceFrame = ReferenceFrame(
            chromosome: "MN908947.3",
            start: 3,
            end: 9,
            pixelWidth: 400,
            sequenceLength: 12
        )
        viewerController.viewerView.setReferenceBundle(bundle)
        viewerController.viewerView.selectVisibleRegion()

        let observation = ThreadObservationBox()
        SequenceViewerView.fastaOperationThreadingProbe = {
            observation.record(isMainThread: Thread.isMainThread)
        }

        XCTAssertTrue(Thread.isMainThread, "Precondition: test body must start on the main thread")
        _ = try await viewerController.viewerView.selectedFASTAOperationInput()

        XCTAssertTrue(observation.fired, "Threading probe never fired — heavy-work path was not exercised")
        XCTAssertFalse(observation.wasMainThread, "selectedFASTAOperationInput ran its bundle I/O on the main thread")
    }

    func testZoomToFitUsesReferenceFrameLengthWhenSequenceIsNotLoaded() {
        let viewerController = ViewerViewController()
        viewerController.loadView()
        viewerController.referenceFrame = ReferenceFrame(
            chromosome: "chr1", start: 7, end: 13, pixelWidth: 400, sequenceLength: 40
        )

        viewerController.zoomToFit()

        XCTAssertEqual(viewerController.referenceFrame?.start, 0)
        XCTAssertEqual(viewerController.referenceFrame?.end, 40)
    }

    func testRulerSelectionPersistsExplicitCoordinatesAndZoomsExactlyToThem() {
        let viewerController = ViewerViewController()
        viewerController.loadView()
        viewerController.referenceFrame = ReferenceFrame(
            chromosome: "chr1", start: 0, end: 40, pixelWidth: 400, sequenceLength: 40
        )
        var selectionUpdates = 0
        viewerController.onSequenceRegionSelectionChanged = { _ in selectionUpdates += 1 }

        viewerController.viewerView.testSetUserSelectionRange(8..<19)
        viewerController.zoomToSelectedRegion()

        XCTAssertEqual(viewerController.explicitAlignmentSelection, .init(contig: "chr1", start: 8, end: 19))
        XCTAssertGreaterThan(selectionUpdates, 0)
        XCTAssertEqual(viewerController.referenceFrame?.start, 8)
        XCTAssertEqual(viewerController.referenceFrame?.end, 19)
    }

    func testZoomToSelectedContextActionRequiresExplicitSelection() throws {
        let viewerController = ViewerViewController()
        viewerController.loadView()
        viewerController.referenceFrame = ReferenceFrame(
            chromosome: "chr1", start: 5, end: 15, pixelWidth: 400, sequenceLength: 40
        )

        viewerController.viewerView.selectVisibleRegion()
        let visibleRangeMenu = viewerController.viewerView.testBuildContextMenu(
            for: .sequence,
            genomicPosition: 9
        )

        XCTAssertNil(
            visibleRangeMenu.items.first { $0.title == "Zoom to Selected Region" },
            "A visible-range fallback must not expose an action that requires an explicit selection"
        )

        viewerController.viewerView.testSetUserSelectionRange(8..<19)
        let explicitRangeMenu = viewerController.viewerView.testBuildContextMenu(
            for: .sequence,
            genomicPosition: 9
        )
        let zoomItem = try XCTUnwrap(
            explicitRangeMenu.items.first { $0.title == "Zoom to Selected Region" }
        )

        XCTAssertEqual(zoomItem.action, #selector(SequenceViewerView.zoomToSelectionAction(_:)))
        XCTAssertTrue(zoomItem.target === viewerController.viewerView)
    }

    // MARK: - Generation guard (stale fetch cannot commit after a newer request begins)
    //
    // Controlled-ordering regression tests in the style of
    // SequenceViewerFetchInvalidationTests: an older, still in-flight fetch is deterministically
    // held mid-flight (via the `fastaOperationFetchGate` debug seam), a newer request is started
    // and allowed to complete first (bumping `fastaOperationFetchGeneration`), and only then is
    // the older fetch released. Both go through the real `@objc`-adjacent production entry
    // points (`copyAnnotationSequenceImpl`, `runSelectedSequenceFASTAOperation`), not a
    // hand-rolled reimplementation of the guard.

    func testStaleAnnotationCopyCannotCommitAfterNewerCopyBegins() async throws {
        let bundleURL = try makeReferenceBundle(chromosomeName: "MN908947", sequence: "AAACCCGGGTTT")
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        viewer.setReferenceBundle(bundle)

        // Two distinct annotations so the pasteboard content unambiguously identifies which
        // fetch's result actually landed.
        let staleAnnotation = SequenceAnnotation(
            type: .gene, name: "stale-gene", chromosome: "MN908947", start: 3, end: 6
        )
        let freshAnnotation = SequenceAnnotation(
            type: .gene, name: "fresh-gene", chromosome: "MN908947", start: 9, end: 12
        )
        let staleExpectedBases = try bundle.fetchSequenceSync(
            region: GenomicRegion(chromosome: "MN908947", start: 3, end: 6)
        )
        let freshExpectedBases = try bundle.fetchSequenceSync(
            region: GenomicRegion(chromosome: "MN908947", start: 9, end: 12)
        )
        XCTAssertNotEqual(staleExpectedBases, freshExpectedBases, "Precondition: fixtures must be distinguishable")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("sentinel-before-either-fetch", forType: .string)

        let gate = GatedFetchController()
        SequenceViewerView.fastaOperationFetchGate = { await gate.waitUntilReleased() }
        defer { SequenceViewerView.fastaOperationFetchGate = nil }

        // Start the stale fetch. It will suspend inside the detached body at the gate, having
        // already captured its generation via `fastaOperationFetchGeneration += 1` synchronously
        // before this call returns control to the caller (the `+= 1` and capture happen
        // synchronously at the top of `copyAnnotationSequenceImpl`, before the `Task` body's
        // first `await`).
        viewer.copyAnnotationSequenceImpl(staleAnnotation)
        await gate.waitUntilFetchHasStarted()

        // Now run a second, ungated copy to completion. This bumps
        // `fastaOperationFetchGeneration` and writes its own (correct) result to the pasteboard.
        SequenceViewerView.fastaOperationFetchGate = nil
        viewer.copyAnnotationSequenceImpl(freshAnnotation)
        try await waitUntilPasteboardContains(freshExpectedBases, pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), freshExpectedBases)

        // Release the stale fetch. Its bundle I/O will now complete, but its generation no
        // longer matches, so its clipboard-write branch must be skipped entirely.
        await gate.release()

        // Give the released stale Task a chance to run to completion and (incorrectly, if the
        // guard were broken) overwrite the pasteboard.
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            freshExpectedBases,
            "Stale annotation-copy fetch overwrote the pasteboard after a newer copy had already committed"
        )
    }

    func testStaleFASTAOperationInputCannotPresentDialogAfterNewerRequestBegins() async throws {
        let bundleURL = try makeReferenceBundle(chromosomeName: "MN908947", sequence: "AAACCCGGGTTT")
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let viewerController = ViewerViewController()
        viewerController.loadView()
        viewerController.referenceFrame = ReferenceFrame(
            chromosome: "MN908947.3",
            start: 3,
            end: 6,
            pixelWidth: 400,
            sequenceLength: 12
        )
        viewerController.viewerView.setReferenceBundle(bundle)
        viewerController.viewerView.selectVisibleRegion()

        var presentedSuggestedNames: [String] = []
        viewerController.fastaOperationDialogPresenterForTesting = { _, suggestedName, _, _ in
            presentedSuggestedNames.append(suggestedName)
        }

        let gate = GatedFetchController()
        SequenceViewerView.fastaOperationFetchGate = { await gate.waitUntilReleased() }
        defer { SequenceViewerView.fastaOperationFetchGate = nil }

        // Start the stale request over the 3-6 selection; it suspends inside the gate.
        viewerController.viewerView.runSelectedSequenceFASTAOperation(toolID: .reverseComplement)
        await gate.waitUntilFetchHasStarted()

        // Move the selection and fire a second, ungated request that completes first and bumps
        // the generation counter.
        viewerController.referenceFrame?.start = 9
        viewerController.referenceFrame?.end = 12
        viewerController.viewerView.selectVisibleRegion()
        SequenceViewerView.fastaOperationFetchGate = nil
        viewerController.viewerView.runSelectedSequenceFASTAOperation(toolID: .reverseComplement)

        try await waitUntil(timeout: 10) { presentedSuggestedNames.contains("MN908947_10_12") }
        XCTAssertEqual(presentedSuggestedNames, ["MN908947_10_12"])

        // Release the stale request. Even though its own fetch now completes successfully, its
        // generation no longer matches, so it must not present a second (stale) dialog.
        await gate.release()
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            presentedSuggestedNames,
            ["MN908947_10_12"],
            "Stale selectedFASTAOperationInput fetch presented a dialog after a newer request had already superseded it"
        )
    }

    private func waitUntilPasteboardContains(
        _ expected: String,
        pasteboard: NSPasteboard,
        timeout: TimeInterval = 10
    ) async throws {
        try await waitUntil(timeout: timeout) { pasteboard.string(forType: .string) == expected }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            await Task.yield()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Fixture

    private func makeReferenceBundle(
        chromosomeName: String,
        sequence: String
    ) throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent("tiny.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        let fastaContent = ">\(chromosomeName)\n\(sequence)\n"
        try fastaContent.write(
            to: genomeDir.appendingPathComponent("sequence.fa"),
            atomically: true,
            encoding: .utf8
        )

        let offset = ">\(chromosomeName)\n".utf8.count
        try "\(chromosomeName)\t\(sequence.count)\t\(offset)\t\(sequence.count)\t\(sequence.count + 1)\n"
            .write(
                to: genomeDir.appendingPathComponent("sequence.fa.fai"),
                atomically: true,
                encoding: .utf8
            )

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Tiny Reference",
            identifier: "org.lungfish.tests.async-bundle-read",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [
                    ChromosomeInfo(
                        name: chromosomeName,
                        length: Int64(sequence.count),
                        offset: Int64(offset),
                        lineBases: sequence.count,
                        lineWidth: sequence.count + 1
                    )
                ]
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}

/// Lock-protected capture box for the threading probe. Not the production type — test-only,
/// mirroring the pattern used by the sibling B3/F14 threading regression tests.
private final class ThreadObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false
    private var _wasMainThread = false

    func record(isMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _fired = true
        _wasMainThread = isMainThread
    }

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _fired
    }

    var wasMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _wasMainThread
    }
}

/// Test-only controllable gate for `SequenceViewerView.fastaOperationFetchGate`. Lets a test
/// deterministically hold a fetch suspended mid-flight (inside the detached bundle-I/O body,
/// after the threading probe fires but before the real file read) so a second, superseding
/// request can be started and completed first — exercising the generation guard's actual
/// discriminating behavior instead of relying on incidental scheduling/timing.
///
/// Implemented as an `actor` (not a lock-protected `@unchecked Sendable` box) since its state
/// only needs to be touched from `async` call sites here.
private actor GatedFetchController {
    private var hasStarted = false
    private var isReleased = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    /// Awaited from inside the production code's detached body. Signals "fetch has started"
    /// to any waiter, then suspends until `release()` is called.
    func waitUntilReleased() async {
        hasStarted = true
        let waitingStarts = startContinuations
        startContinuations.removeAll()
        for continuation in waitingStarts {
            continuation.resume()
        }
        if isReleased { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    /// Awaited from the test body. Returns once `waitUntilReleased()` has been entered by the
    /// gated fetch (i.e. the fetch has reached the detached body and is now suspended there).
    func waitUntilFetchHasStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    /// Releases every fetch currently suspended in `waitUntilReleased()`, and lets any future
    /// call to `waitUntilReleased()` return immediately (matching a real one-shot gate that has
    /// already been opened).
    func release() {
        isReleased = true
        let waitingReleases = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in waitingReleases {
            continuation.resume()
        }
    }
}
