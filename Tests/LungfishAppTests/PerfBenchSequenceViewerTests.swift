// PerfBenchSequenceViewerTests.swift - Opt-in offscreen draw-time benchmark
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Part of the 2026-09-23 best-practices audit (concurrency-performance.md, WP8 / PERF-09,
// PERF-10). This harness renders SequenceViewerView offscreen into an NSBitmapImageRep at
// 1600x900@2x and reports median draw(_:) time over >=20 passes, for a full redraw and for a
// narrow dirtyRect (a loading-badge-sized rect). It only runs when LUNGFISH_PERF_BENCH=1 is
// set in the environment, so it never slows down the default test run.
//
// The view is populated directly through its internal (accessible via @testable import) cache
// fields rather than by driving the real async fetch pipeline, so the benchmark is
// deterministic and independent of disk/samtools latency. This mirrors production state
// exactly: `drawBundleContent` reads these same fields, and the fetch-trigger checks
// (`*Covered`, `isFetching*`) are satisfied so no fetch is kicked off mid-benchmark.
import AppKit
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishApp

@MainActor
final class PerfBenchSequenceViewerTests: XCTestCase {
    private var tempDirectory: URL!
    // `SequenceViewerView.viewController` is `weak` (production code has the owning
    // split-view controller hold the strong reference). The fixture's local
    // `ViewerViewController` was previously only referenced by that weak property, so it
    // was deallocated the moment `makeReadHeavyViewer` returned — every subsequent
    // `draw(_:)` then saw `viewController == nil`, hit the placeholder branch, and
    // `drawBundleContent` never ran. That is what made the benchmark implausibly fast
    // (it was timing a no-op draw). Retaining it here for the test's lifetime is the fix.
    private var retainedViewController: ViewerViewController?

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LUNGFISH_PERF_BENCH"] == "1",
            "Set LUNGFISH_PERF_BENCH=1 to run offscreen rendering benchmarks."
        )
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-perf-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        retainedViewController = nil
    }

    // MARK: - Benchmark

    func testFullViewerDrawBenchmark() throws {
        let (viewer, frame) = try makeReadHeavyViewer(readCount: 50_000)
        let bounds = NSRect(x: 0, y: 0, width: 1600, height: 900)

        let fullRedrawMedian = try medianDrawSeconds(view: viewer, dirtyRect: bounds, passes: 20)
        // A narrow rect roughly the size of a loading badge, positioned over the read track
        // so it exercises the same code paths a badge-only invalidation would repaint.
        let badgeRect = NSRect(x: 8, y: viewer.readTrackY + 2, width: 200, height: 40)
        let badgeRedrawMedian = try medianDrawSeconds(view: viewer, dirtyRect: badgeRect, passes: 20)

        reportBenchmark(
            name: "SequenceViewerView full redraw (50k packed reads, 1600x900@2x)",
            medianSeconds: fullRedrawMedian
        )
        reportBenchmark(
            name: "SequenceViewerView narrow dirtyRect redraw (200x40 badge rect)",
            medianSeconds: badgeRedrawMedian
        )
        _ = frame
    }

    // MARK: - Measurement

    private func medianDrawSeconds(view: NSView, dirtyRect: NSRect, passes: Int) throws -> Double {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        var samples: [Double] = []
        samples.reserveCapacity(passes)
        for _ in 0..<passes {
            let start = CFAbsoluteTimeGetCurrent()
            // cacheDisplay always renders the view's full bounds through NSView's normal
            // path, so to measure a narrow dirtyRect specifically we invoke draw(_:) directly
            // against a manually pushed graphics context, matching what AppKit does for a
            // partial invalidation.
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
                throw XCTSkip("No offscreen graphics context available")
            }
            NSGraphicsContext.current = context
            view.draw(dirtyRect)
            context.flushGraphics()
            samples.append(CFAbsoluteTimeGetCurrent() - start)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    private func reportBenchmark(name: String, medianSeconds: Double) {
        let ms = medianSeconds * 1000
        // XCTAttachment-free plain print so `swift test` output captures it directly;
        // this is a benchmark report, not a pass/fail assertion.
        print("[LUNGFISH_PERF_BENCH] \(name): median \(String(format: "%.3f", ms)) ms")
    }

    // MARK: - Fixture construction

    /// Builds a SequenceViewerView wired to a minimal on-disk reference bundle and populates
    /// its read/annotation/variant/coverage caches directly so `drawBundleContent` renders a
    /// realistic packed-reads scene without touching the async fetch pipeline.
    private func makeReadHeavyViewer(readCount: Int) throws -> (SequenceViewerView, ReferenceFrame) {
        let chromosome = "bench-chr1"
        let chromLength = 2_000_000
        let bundleURL = try makeMinimalReferenceBundle(chromosome: chromosome, length: chromLength)
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))

        let viewController = ViewerViewController()
        viewController.loadView()
        // See `retainedViewController`'s doc comment: `SequenceViewerView.viewController`
        // is `weak`, so the fixture must keep a strong reference alive for the whole test.
        retainedViewController = viewController

        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
        viewer.viewController = viewController
        viewer.setReferenceBundle(bundle)

        // The visible span must keep `scale = span / pixelWidth` at or below
        // `ReadViewportPolicy.coverageThresholdBpPerPx` (2.0 bp/px) so `applyReadViewportPolicy`
        // resolves to `.packed` rather than `.coverage` — at `.coverage` zoom the read track
        // draws only a hint and never packs or paints individual reads at all, which is the
        // harness bug this benchmark exists to avoid repeating. 2,000 bp over a 1,600 px
        // viewport is 1.25 bp/px, comfortably under the threshold and still above the 0.6
        // bp/px base-letter threshold, so the packed (not base) tier renders.
        let visibleStart = 100_000
        let visibleEnd = 102_000
        let referenceFrame = ReferenceFrame(
            chromosome: chromosome,
            start: Double(visibleStart),
            end: Double(visibleEnd),
            pixelWidth: 1600,
            sequenceLength: chromLength
        )
        viewController.referenceFrame = referenceFrame

        let visibleRegion = GenomicRegion(chromosome: chromosome, start: visibleStart, end: visibleEnd)

        // Satisfy every `*Covered` check in drawBundleContent so draw(_:) never triggers a
        // real async fetch mid-benchmark; each region is set to the whole chromosome.
        let wholeChromosome = GenomicRegion(chromosome: chromosome, start: 0, end: chromLength)
        viewer.cachedAnnotationRegion = wholeChromosome
        viewer.cachedBundleAnnotations = []
        viewer.cachedVariantRegion = wholeChromosome
        viewer.cachedVariantAnnotations = []
        viewer.cachedDepthRegion = wholeChromosome
        viewer.cachedDepthPoints = syntheticCoveragePoints(start: visibleStart, end: visibleEnd)
        viewer.cachedReadRegion = wholeChromosome
        viewer.alignmentDataProviders = [(
            trackId: "bench-track",
            provider: AlignmentDataProvider(
                alignmentPath: bundleURL.appendingPathComponent("bench.bam").path,
                indexPath: bundleURL.appendingPathComponent("bench.bam.bai").path
            )
        )]

        let reads = syntheticReads(
            count: readCount,
            chromosome: chromosome,
            windowStart: visibleStart - 5_000,
            windowEnd: visibleEnd + 5_000
        )
        viewer.cachedAlignedReads = reads
        viewer.layoutSubtreeIfNeeded()

        // `draw(_:)` computes its own `ReadPackCacheKey` from the viewport, scale, row-limit
        // and sort settings (SequenceViewerView+Rendering.swift), and only paints reads when
        // `cachedPackKey` already equals that key. Hand-rolling an equivalent key here
        // previously drifted from the production formula (padding window and row-limit
        // defaults did not match), so `layoutIsCurrent` was always false and every benchmark
        // pass measured an early return that painted zero reads — the implausible ~0.6ms.
        //
        // Instead, drive a real (headless) draw so `requestBackgroundPack` computes and
        // records the exact key it wants under `inFlightPackKey`, pack synchronously with
        // that key's own parameters, and commit it exactly as the real background task would.
        // A second draw pass then finds `cachedPackKey == key` and takes the normal paint path.
        try triggerBackgroundPackKey(for: viewer)
        guard let key = viewer.inFlightPackKey else {
            throw XCTSkip("draw(_:) did not queue a background pack; nothing to benchmark")
        }
        let readsForPacking = reads.filter { read in
            guard let window = key.filterWindow else { return true }
            return read.chromosome == chromosome
                && read.alignmentEnd > window.lowerBound
                && read.position < window.upperBound
        }
        let (packed, overflow) = ReadTrackRenderer.packReads(
            readsForPacking,
            frame: referenceFrame,
            maxRows: key.maxRows,
            sortMode: .position,
            sortPosition: key.sortPosition,
            prioritizedRegion: key.prioritizedRegion
        )
        _ = viewer.commitPackedLayout(
            generation: viewer.packRequestGeneration,
            key: key,
            packed: packed,
            overflow: overflow
        )
        guard viewer.testCachedPackedReadLayout != nil, !viewer.cachedPackedReads.isEmpty else {
            throw XCTSkip("Packed layout did not commit; nothing to benchmark")
        }

        return (viewer, referenceFrame)
    }

    /// Renders one headless pass so `drawBundleContent` reaches its read-track block and calls
    /// `requestBackgroundPack`, which records the key it wants in `inFlightPackKey` without
    /// actually running the packer (that happens on `Task.detached`, which this synchronous
    /// helper does not await). The caller packs that same key synchronously instead.
    private func triggerBackgroundPackKey(for viewer: SequenceViewerView) throws {
        guard let rep = viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds) else {
            throw XCTSkip("No offscreen bitmap rep available")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw XCTSkip("No offscreen graphics context available")
        }
        NSGraphicsContext.current = context
        viewer.draw(viewer.bounds)
        context.flushGraphics()
        viewer.backgroundPackTask?.cancel()
        viewer.backgroundPackTask = nil
    }

    private func syntheticReads(count: Int, chromosome: String, windowStart: Int, windowEnd: Int) -> [AlignedRead] {
        var reads: [AlignedRead] = []
        reads.reserveCapacity(count)
        let span = max(1, windowEnd - windowStart)
        let readLength = 150
        let bases = "ACGT"
        let baseBytes = Array(bases.utf8)
        for index in 0..<count {
            let position = windowStart + (index * 37) % span
            var sequence = String()
            sequence.reserveCapacity(readLength)
            for offset in 0..<readLength {
                sequence.append(Character(UnicodeScalar(baseBytes[(index + offset) % baseBytes.count])))
            }
            let read = AlignedRead(
                name: "bench-read-\(index)",
                flag: index.isMultiple(of: 2) ? 0 : 16,
                chromosome: chromosome,
                position: position,
                mapq: 60,
                cigar: [CIGAROperation(op: .match, length: readLength)],
                sequence: sequence,
                qualities: Array(repeating: UInt8(30), count: readLength)
            )
            reads.append(read)
        }
        return reads
    }

    private func syntheticCoveragePoints(start: Int, end: Int) -> [ReadTrackRenderer.CoveragePoint] {
        stride(from: start, to: end, by: 10).map {
            ReadTrackRenderer.CoveragePoint(position: $0, depth: Int.random(in: 20...400))
        }
    }

    private func makeMinimalReferenceBundle(chromosome: String, length: Int) throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent("bench.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        // A short repeated-motif sequence is enough; the benchmark never zooms in far enough
        // to require fetching bases (visible span is 10kb, well above showLineThreshold).
        let sequence = String(repeating: "ACGT", count: length / 4)
        try sequence.write(
            to: genomeDir.appendingPathComponent("sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        let offset = ">\(chromosome)\n".utf8.count
        try "\(chromosome)\t\(sequence.count)\t\(offset)\t\(sequence.count)\t\(sequence.count + 1)\n"
            .write(to: genomeDir.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Perf Bench Reference",
            identifier: "org.lungfish.tests.perf-bench",
            source: SourceInfo(organism: "Test organism", assembly: "bench"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [
                    ChromosomeInfo(
                        name: chromosome,
                        length: Int64(length),
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
