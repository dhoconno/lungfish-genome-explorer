// SequenceViewerDirtyRectPixelDiffTests.swift - Pixel-identity guard for the PERF-09 dirtyRect skip
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// 2026-09-23 best-practices audit (concurrency-performance.md, WP8 / "SequenceViewerView
// draw(_:) ignores dirtyRect and repaints every track"). `drawBundleContent` now skips the
// coverage-strip and packed/base-read draw calls when their vertical band does not intersect
// the dirtyRect AppKit actually asked to repaint. This must never change what a FULL redraw
// paints — a full redraw's dirtyRect always covers the whole view, so every band still
// intersects it. This test renders the same populated viewer twice (full bounds dirtyRect vs.
// bounds dirtyRect, i.e. what AppKit does on setNeedsDisplay(bounds)) and asserts the two
// bitmaps are pixel-identical, then separately asserts a narrow dirtyRect still leaves the
// pixels inside that rect correct by comparing against the full redraw's pixels in that same
// sub-region.
import AppKit
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishApp

@MainActor
final class SequenceViewerDirtyRectPixelDiffTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-dirtyrect-pixel-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testFullBoundsRedrawIsPixelIdenticalRegardlessOfHowItIsInvoked() throws {
        let (viewer, _) = try makeReadHeavyViewer(readCount: 2_000)
        let bounds = viewer.bounds

        // Two independent full-bounds renders. `cacheDisplay(in:to:)` invokes `draw(_:)` with
        // the given rect as the dirtyRect, so both of these pass `bounds` as dirtyRect — exactly
        // what AppKit's own `setNeedsDisplay(bounds)` does. If the dirtyRect skip only fired for
        // narrower rects (as intended), these two renders must be byte-identical.
        let repA = try XCTUnwrap(viewer.bitmapImageRepForCachingDisplay(in: bounds))
        viewer.cacheDisplay(in: bounds, to: repA)
        let repB = try XCTUnwrap(viewer.bitmapImageRepForCachingDisplay(in: bounds))
        viewer.cacheDisplay(in: bounds, to: repB)

        assertPixelIdentical(repA, repB, region: nil)
    }

    func testNarrowDirtyRectPaintsTheSamePixelsAsAFullRedrawWithinThatRect() throws {
        let (viewer, _) = try makeReadHeavyViewer(readCount: 2_000)
        let bounds = viewer.bounds

        let fullRep = try XCTUnwrap(viewer.bitmapImageRepForCachingDisplay(in: bounds))
        viewer.cacheDisplay(in: bounds, to: fullRep)

        // A loading-badge-sized rect positioned over the read track, mirroring the shape of
        // invalidation `drawReadLoadingBadge`'s rect accumulator produces.
        let badgeRect = NSRect(x: 8, y: viewer.readTrackY + 2, width: 200, height: 40)
        // `cacheDisplay(in:to:)` paints `rect`'s content starting at the REP's own origin
        // (0,0), not at `rect`'s position within the view — so the rep here must be sized to
        // `badgeRect` itself, and compared against the matching sub-rectangle of `fullRep`
        // (which IS addressed in full-view pixel coordinates), not against `badgeRect`'s own
        // position inside a full-size rep.
        let narrowRep = try XCTUnwrap(viewer.bitmapImageRepForCachingDisplay(in: badgeRect))
        viewer.cacheDisplay(in: badgeRect, to: narrowRep)

        assertPixelIdentical(fullRep, narrowRep, fullRegion: badgeRect, viewBounds: bounds)
    }

    // MARK: - Pixel comparison

    /// Compares two full-view-sized, pixel-aligned renders (both produced with the same
    /// dirtyRect passed to `cacheDisplay`, e.g. two independent full-bounds redraws).
    private func assertPixelIdentical(
        _ repA: NSBitmapImageRep,
        _ repB: NSBitmapImageRep,
        region: NSRect? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(repA.pixelsWide, repB.pixelsWide, file: file, line: line)
        XCTAssertEqual(repA.pixelsHigh, repB.pixelsHigh, file: file, line: line)
        guard repA.pixelsWide == repB.pixelsWide, repA.pixelsHigh == repB.pixelsHigh else { return }
        compareRegion(
            repA, at: (0, 0), repB, at: (0, 0),
            widthPx: repA.pixelsWide, heightPx: repA.pixelsHigh,
            file: file, line: line
        )
    }

    /// Compares `fullRep` (sized to the whole view, addressed in full-view pixel coordinates)
    /// against `narrowRep` (sized and addressed to only `fullRegion`, because
    /// `cacheDisplay(in:to:)` always paints starting at a rep's own pixel origin regardless of
    /// where the requested rect sits within the view).
    private func assertPixelIdentical(
        _ fullRep: NSBitmapImageRep,
        _ narrowRep: NSBitmapImageRep,
        fullRegion: NSRect,
        viewBounds: NSRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scaleX = CGFloat(fullRep.pixelsWide) / viewBounds.width
        let scaleY = CGFloat(fullRep.pixelsHigh) / viewBounds.height
        let originXInFull = Int((fullRegion.minX * scaleX).rounded())
        // Flipped view: view-space minY is nearer the top, which is pixel row 0 in both reps.
        let originYInFull = Int((fullRegion.minY * scaleY).rounded())
        let widthPx = min(narrowRep.pixelsWide, fullRep.pixelsWide - originXInFull)
        let heightPx = min(narrowRep.pixelsHigh, fullRep.pixelsHigh - originYInFull)
        guard widthPx > 0, heightPx > 0 else {
            XCTFail("Computed an empty comparison region", file: file, line: line)
            return
        }
        compareRegion(
            fullRep, at: (originXInFull, originYInFull), narrowRep, at: (0, 0),
            widthPx: widthPx, heightPx: heightPx,
            file: file, line: line
        )
    }

    private func compareRegion(
        _ repA: NSBitmapImageRep, at originA: (x: Int, y: Int),
        _ repB: NSBitmapImageRep, at originB: (x: Int, y: Int),
        widthPx: Int, heightPx: Int,
        file: StaticString, line: UInt
    ) {
        var mismatches = 0
        var firstMismatch: (Int, Int)?
        for dy in 0..<heightPx {
            for dx in 0..<widthPx {
                guard let colorA = repA.colorAt(x: originA.x + dx, y: originA.y + dy),
                      let colorB = repB.colorAt(x: originB.x + dx, y: originB.y + dy) else { continue }
                if !colorsApproximatelyEqual(colorA, colorB) {
                    mismatches += 1
                    if firstMismatch == nil { firstMismatch = (dx, dy) }
                }
            }
        }
        let totalPixels = widthPx * heightPx
        XCTAssertEqual(
            mismatches, 0,
            "\(mismatches) of \(totalPixels) sampled pixels differed; first mismatch at offset \(String(describing: firstMismatch))",
            file: file, line: line
        )
    }

    /// Small tolerance for font anti-aliasing / color-space rounding noise between two
    /// otherwise-identical renders, not for genuine content differences.
    private func colorsApproximatelyEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.deviceRGB), let b = b.usingColorSpace(.deviceRGB) else { return a == b }
        let tolerance: CGFloat = 1.0 / 255.0
        return abs(a.redComponent - b.redComponent) <= tolerance
            && abs(a.greenComponent - b.greenComponent) <= tolerance
            && abs(a.blueComponent - b.blueComponent) <= tolerance
            && abs(a.alphaComponent - b.alphaComponent) <= tolerance
    }

    // MARK: - Fixture construction (mirrors PerfBenchSequenceViewerTests' approach, at a smaller
    // scale suitable for per-pixel comparison rather than timing)

    private func makeReadHeavyViewer(readCount: Int) throws -> (SequenceViewerView, ReferenceFrame) {
        let chromosome = "pixdiff-chr1"
        let chromLength = 2_000_000
        let bundleURL = try makeMinimalReferenceBundle(chromosome: chromosome, length: chromLength)
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))

        let viewController = ViewerViewController()
        viewController.loadView()

        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        viewer.viewController = viewController
        viewer.setReferenceBundle(bundle)

        let visibleStart = 100_000
        let visibleEnd = 110_000
        let referenceFrame = ReferenceFrame(
            chromosome: chromosome,
            start: Double(visibleStart),
            end: Double(visibleEnd),
            pixelWidth: 800,
            sequenceLength: chromLength
        )
        viewController.referenceFrame = referenceFrame

        let wholeChromosome = GenomicRegion(chromosome: chromosome, start: 0, end: chromLength)
        viewer.cachedAnnotationRegion = wholeChromosome
        viewer.cachedBundleAnnotations = []
        viewer.cachedVariantRegion = wholeChromosome
        viewer.cachedVariantAnnotations = []
        viewer.cachedDepthRegion = wholeChromosome
        viewer.cachedDepthPoints = stride(from: visibleStart, to: visibleEnd, by: 10).map {
            ReadTrackRenderer.CoveragePoint(position: $0, depth: Int.random(in: 20...400))
        }
        viewer.cachedReadRegion = wholeChromosome
        viewer.alignmentDataProviders = [(
            trackId: "pixdiff-track",
            provider: AlignmentDataProvider(
                alignmentPath: bundleURL.appendingPathComponent("bench.bam").path,
                indexPath: bundleURL.appendingPathComponent("bench.bam.bai").path
            )
        )]

        var reads: [AlignedRead] = []
        reads.reserveCapacity(readCount)
        let windowStart = visibleStart - 5_000
        let windowEnd = visibleEnd + 5_000
        let span = max(1, windowEnd - windowStart)
        for index in 0..<readCount {
            let position = windowStart + (index * 37) % span
            let read = AlignedRead(
                name: "pixdiff-read-\(index)",
                flag: index.isMultiple(of: 2) ? 0 : 16,
                chromosome: chromosome,
                position: position,
                mapq: 60,
                cigar: [CIGAROperation(op: .match, length: 100)],
                sequence: String(repeating: "ACGT", count: 25),
                qualities: Array(repeating: UInt8(30), count: 100)
            )
            reads.append(read)
        }
        viewer.cachedAlignedReads = reads

        let (packed, overflow) = ReadTrackRenderer.packReads(
            reads,
            frame: referenceFrame,
            maxRows: 75,
            sortMode: .position,
            sortPosition: nil,
            prioritizedRegion: visibleStart..<visibleEnd
        )
        let key = ReadPackCacheKey(
            readGeneration: viewer.cachedReadSetGeneration,
            chromosome: chromosome,
            scaleTier: ReadPackCacheKey.quantizeScale(referenceFrame.scale),
            sortMode: "position",
            sortPosition: nil,
            maxRows: 75,
            verticalCompress: false,
            prioritizedRegion: nil,
            filterWindow: windowStart..<windowEnd
        )
        viewer.installPackedLayout(key: key, packed: packed, overflow: overflow)

        viewer.layoutSubtreeIfNeeded()
        return (viewer, referenceFrame)
    }

    private func makeMinimalReferenceBundle(chromosome: String, length: Int) throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent("pixdiff.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)

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
            name: "Pixel Diff Reference",
            identifier: "org.lungfish.tests.pixel-diff-bench",
            source: SourceInfo(organism: "Test organism", assembly: "pixdiff"),
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
