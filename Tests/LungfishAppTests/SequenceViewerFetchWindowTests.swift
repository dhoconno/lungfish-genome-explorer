// SequenceViewerFetchWindowTests.swift - The fetch window and the draw that starts it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 walk WO-4. A 500 kb reference at full width (1 to 500,001) showed "Fetching sequence..."
// for good and never drew, while the serial sequenceFetch queue held a core. The fetch window is
// capped at `sequenceFetchCapKb * 1000` (500,000 bases by default), so a 500,001-base view was
// fetched as 0 to 500,000, one base short. The cache never covered the view and every redraw
// started the fetch again. A view wider than the cap now starts no fetch and draws the low-zoom
// line. A view at or under the cap always gets a window that covers it.

import AppKit
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishApp

@MainActor
final class SequenceViewerFetchWindowTests: XCTestCase {
    private let chromosome = "chr1"
    private let defaultCapBases = 500_000

    private func window(
        _ start: Int,
        _ end: Int,
        chromosomeLength: Int = 100_000_000,
        capBases: Int = 500_000
    ) -> GenomicRegion? {
        SequenceViewerView.sequenceFetchWindow(
            visible: GenomicRegion(chromosome: chromosome, start: start, end: end),
            chromosomeLength: chromosomeLength,
            capBases: capBases
        )
    }

    /// ARCH-WALK WO-4. Whatever the function returns for this view, it is never a window that
    /// falls short of the view.
    func testWindowCoversA500001BaseViewAtTheDefaultCap() {
        let visible = GenomicRegion(chromosome: chromosome, start: 0, end: 500_001)
        if let result = window(0, 500_001, chromosomeLength: 600_000, capBases: defaultCapBases) {
            XCTAssertTrue(
                result.start <= visible.start && result.end >= visible.end,
                "the window \(result.start)-\(result.end) falls short of the view \(visible.start)-\(visible.end)"
            )
        }
    }

    func testAViewWiderThanTheCapStartsNoFetch() {
        XCTAssertNil(
            window(0, 500_001, chromosomeLength: 600_000),
            "a 500,001-base view is wider than the 500,000-base cap"
        )
        XCTAssertNil(window(40_000_000, 60_000_000), "a 20 Mb view of a 100 Mb chromosome")
        XCTAssertNil(
            window(0, 100_001, chromosomeLength: 1_000_000, capBases: 100_000),
            "a 100,001-base view at the smallest cap, 100 Kb"
        )
    }

    func testAViewAtOrUnderTheCapIsAlwaysCoveredByItsWindow() throws {
        let chromosomeLength = 2_000_000
        let spans = [1, 400, 5_000, 50_000, 99_999, 100_000, 100_001, 250_000, 333_333, 499_999, 500_000]
        for span in spans {
            let starts = [0, 1, 777, 250_000, chromosomeLength - span - 1, chromosomeLength - span]
            for start in starts {
                let end = start + span
                let result = try XCTUnwrap(
                    window(start, end, chromosomeLength: chromosomeLength),
                    "a \(span)-base view at \(start) is at or under the cap"
                )
                XCTAssertLessThanOrEqual(result.start, start, "\(span) bases at \(start)")
                XCTAssertGreaterThanOrEqual(result.end, end, "\(span) bases at \(start)")
                XCTAssertGreaterThanOrEqual(result.start, 0, "\(span) bases at \(start)")
                XCTAssertLessThanOrEqual(result.end, chromosomeLength, "\(span) bases at \(start)")
            }
        }
    }

    /// The 400-base and 50 kb views still fetch, with a buffer of at least 100 Kb for panning.
    func testA400BaseViewAndA50KbViewKeepAWindowWithABufferForPanning() throws {
        for (start, end) in [(100_000, 100_400), (100_000, 150_000)] {
            let result = try XCTUnwrap(window(start, end), "the view \(start)-\(end) must fetch")
            XCTAssertLessThanOrEqual(result.start, start)
            XCTAssertGreaterThanOrEqual(result.end, end)
            XCTAssertGreaterThanOrEqual(result.length, 100_000, "the view \(start)-\(end)")
        }
    }

    /// A view that runs past the chromosome end is clamped to a window that cannot cover it.
    func testAViewPastTheChromosomeEndStartsNoFetch() {
        XCTAssertNil(
            window(99_000, 100_001, chromosomeLength: 100_000),
            "the window ends at the chromosome end, one base short of the view"
        )
        XCTAssertNotNil(window(99_000, 100_000, chromosomeLength: 100_000))
    }
}

/// The draw that starts the fetch, on a real reference bundle of 600,000 bases.
@MainActor
final class SequenceViewerFetchDrawTests: XCTestCase {
    private let chromosome = "chr1"
    private let chromosomeLength = 600_000
    private var tempDirectory: URL!
    private var originalCapKb = 500
    // `SequenceViewerView.viewController` is weak, so the test keeps the owner alive.
    private var retainedViewController: ViewerViewController?

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-fetch-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        originalCapKb = AppSettings.shared.sequenceFetchCapKb
        AppSettings.shared.sequenceFetchCapKb = 500
    }

    override func tearDownWithError() throws {
        AppSettings.shared.sequenceFetchCapKb = originalCapKb
        retainedViewController = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testTwoDrawsOfAViewAt500001BasesStartAtMostOneFetch() async throws {
        let viewer = try makeViewer(frameStart: 0, frameEnd: 500_001)
        try draw(viewer)
        await settleFetch(of: viewer)
        try draw(viewer)
        await settleFetch(of: viewer)
        XCTAssertLessThanOrEqual(
            viewer.sequenceFetchGeneration, 1,
            "two draws of the same frame started \(viewer.sequenceFetchGeneration) fetches"
        )
    }

    func testAViewWiderThanTheCapDrawsTheLineAndStartsNoFetch() async throws {
        let viewer = try makeViewer(frameStart: 0, frameEnd: 500_001)
        try draw(viewer)
        let started = viewer.sequenceFetchGeneration
        let fetching = viewer.isFetchingBundleData
        await settleFetch(of: viewer)
        XCTAssertEqual(started, 0, "no fetch can cover a view wider than the cap")
        XCTAssertFalse(fetching, "the track must not read Fetching sequence... while nothing useful is fetched")
        XCTAssertNil(viewer.cachedBundleSequence?.count, "no sequence is cached for a view wider than the cap")
    }

    func testTheFetchingLabelNeverShowsForAViewWiderThanTheCap() {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1600, height: 400))
        let wide = ReferenceFrame(
            chromosome: chromosome, start: 0, end: 500_001, pixelWidth: 1600, sequenceLength: chromosomeLength
        )
        let narrow = ReferenceFrame(
            chromosome: chromosome, start: 100_000, end: 150_000, pixelWidth: 1600, sequenceLength: chromosomeLength
        )
        // A fetch for an earlier, narrower view is still in flight.
        viewer.isFetchingBundleData = true
        XCTAssertFalse(viewer.showsFetchingSequenceLabel(frame: wide), "that fetch cannot cover a view wider than the cap")
        XCTAssertTrue(viewer.showsFetchingSequenceLabel(frame: narrow), "a fetch that can cover the view shows the words")
        viewer.isFetchingBundleData = false
        XCTAssertFalse(viewer.showsFetchingSequenceLabel(frame: narrow), "no fetch runs, so no words")
    }

    /// The 400-base view fetches once, lands a cache that covers it, and then draws from the cache.
    func testA400BaseViewFetchesOnceAndThenDrawsFromTheCache() async throws {
        let viewer = try makeViewer(frameStart: 100_000, frameEnd: 100_400)
        try draw(viewer)
        XCTAssertEqual(viewer.sequenceFetchGeneration, 1)
        await settleFetch(of: viewer)
        let cached = try XCTUnwrap(viewer.cachedSequenceRegion, "the fetch landed no sequence")
        XCTAssertLessThanOrEqual(cached.start, 100_000)
        XCTAssertGreaterThanOrEqual(cached.end, 100_400)
        XCTAssertNotNil(viewer.cachedBundleSequence)
        try draw(viewer)
        XCTAssertEqual(viewer.sequenceFetchGeneration, 1, "the cache covers the view, so the second draw starts no fetch")
    }

    // MARK: - Fixture

    private func settleFetch(of viewer: SequenceViewerView) async {
        await waitUntil(budget: .lookup) { !viewer.isFetchingBundleData }
    }

    private func draw(_ viewer: SequenceViewerView) throws {
        let rep = try XCTUnwrap(viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds))
        viewer.cacheDisplay(in: viewer.bounds, to: rep)
    }

    private func makeViewer(frameStart: Int, frameEnd: Int) throws -> SequenceViewerView {
        let bundleURL = try makeReferenceBundle()
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let viewController = ViewerViewController()
        viewController.loadView()
        retainedViewController = viewController

        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1600, height: 400))
        viewer.viewController = viewController
        viewer.setReferenceBundle(bundle)
        viewController.referenceFrame = ReferenceFrame(
            chromosome: chromosome,
            start: Double(frameStart),
            end: Double(frameEnd),
            pixelWidth: 1600,
            sequenceLength: chromosomeLength
        )
        // The annotation cache covers the chromosome, so a draw starts only the sequence fetch.
        viewer.cachedAnnotationRegion = GenomicRegion(chromosome: chromosome, start: 0, end: chromosomeLength)
        viewer.cachedBundleAnnotations = []
        viewer.layoutSubtreeIfNeeded()
        return viewer
    }

    private func makeReferenceBundle() throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent("fetch-window.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        let sequence = String(repeating: "ACGT", count: chromosomeLength / 4)
        let header = ">\(chromosome)\n"
        try "\(header)\(sequence)\n".write(
            to: genomeDir.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8
        )
        let offset = header.utf8.count
        try "\(chromosome)\t\(sequence.count)\t\(offset)\t\(sequence.count)\t\(sequence.count + 1)\n"
            .write(to: genomeDir.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Fetch Window Reference",
            identifier: "org.lungfish.tests.fetch-window",
            source: SourceInfo(organism: "Test organism", assembly: "fetch-window"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [
                    ChromosomeInfo(
                        name: chromosome,
                        length: Int64(chromosomeLength),
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
