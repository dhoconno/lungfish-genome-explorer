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
