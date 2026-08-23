// ReadLayoutCacheTests.swift - Pack caching, visible-range culling, mismatch precomputation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

@MainActor
final class ReadLayoutCacheTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRead(
        name: String,
        position: Int,
        length: Int = 100,
        chromosome: String = "chr1",
        mdTag: String? = nil,
        sequence: String? = nil
    ) -> AlignedRead {
        AlignedRead(
            name: name,
            flag: 0,
            chromosome: chromosome,
            position: position,
            mapq: 60,
            cigar: [CIGAROperation(op: .match, length: length)],
            sequence: sequence ?? String(repeating: "A", count: length),
            qualities: Array(repeating: 30, count: length),
            mdTag: mdTag
        )
    }

    /// Non-overlapping reads pack one-per-row only when they collide; spacing
    /// them far apart keeps them all on row 0, so tests that need many rows
    /// deliberately stack reads at the same position.
    private func stackedReads(count: Int, position: Int = 1_000) -> [AlignedRead] {
        (0..<count).map { makeRead(name: "r\($0)", position: position) }
    }

    private func makeFrame(start: Double = 0, end: Double = 10_000, pixelWidth: Int = 1_000) -> ReferenceFrame {
        ReferenceFrame(chromosome: "chr1", start: start, end: end, pixelWidth: pixelWidth)
    }

    private func makeView() -> SequenceViewerView {
        SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 600))
    }

    /// Packing now runs off the main thread, so a test that wants to inspect the
    /// resulting layout drains the queued pack synchronously first. The cache
    /// contract these tests protect is unchanged; only its timing is.
    @discardableResult
    private func prepareAndDrain(
        _ view: SequenceViewerView,
        region: GenomicRegion,
        frame: ReferenceFrame
    ) -> (packed: [(row: Int, read: AlignedRead)], overflow: Int, maxRows: Int?) {
        var result = view.prepareDetachedReadLayout(region: region, frame: frame)
        view.testDrainPendingPack(
            reads: view.testCachedAlignedReads.filter { $0.chromosome == region.chromosome },
            frame: ReadPackFrame(frame),
            maxRows: result.maxRows,
            prioritizedRegion: region.start..<region.end
        )
        if result.packed.isEmpty {
            result = view.prepareDetachedReadLayout(region: region, frame: frame)
        }
        return result
    }

    // MARK: - 1. Pack once, not per frame

    func testRepeatedLayoutPreparationWithUnchangedInputsDoesNotRepack() {
        let view = makeView()
        view.testSetCachedAlignedReads(stackedReads(count: 40))
        let region = GenomicRegion(chromosome: "chr1", start: 900, end: 2_000)
        let frame = makeFrame()

        prepareAndDrain(view, region: region, frame: frame)
        let afterFirst = view.backgroundPackInvocationCount
        XCTAssertEqual(afterFirst, 1, "First preparation must pack exactly once")
        XCTAssertEqual(view.packInvocationCount, 0, "Packing must never run on the main thread")

        for _ in 0..<10 {
            _ = view.prepareDetachedReadLayout(region: region, frame: frame)
        }

        XCTAssertEqual(
            view.backgroundPackInvocationCount, afterFirst,
            "Repeat draws with identical inputs must reuse the cached layout"
        )
    }

    func testAssigningNewReadsRepacks() {
        let view = makeView()
        view.testSetCachedAlignedReads(stackedReads(count: 20))
        let region = GenomicRegion(chromosome: "chr1", start: 900, end: 2_000)
        let frame = makeFrame()

        prepareAndDrain(view, region: region, frame: frame)
        let afterFirst = view.backgroundPackInvocationCount

        view.testSetCachedAlignedReads(stackedReads(count: 25))
        _ = view.prepareDetachedReadLayout(region: region, frame: frame)

        XCTAssertEqual(view.backgroundPackInvocationCount, afterFirst + 1, "A new read set must repack")
    }

    func testChangingScaleRepacks() {
        let view = makeView()
        view.testSetCachedAlignedReads(stackedReads(count: 20))
        let region = GenomicRegion(chromosome: "chr1", start: 900, end: 2_000)

        prepareAndDrain(view, region: region, frame: makeFrame(start: 0, end: 10_000))
        let afterFirst = view.backgroundPackInvocationCount

        // Zooming changes bp-per-pixel, which genuinely changes row assignment
        // (minReadPixels culling + the 2px inter-read gap are pixel-space).
        _ = view.prepareDetachedReadLayout(region: region, frame: makeFrame(start: 0, end: 2_000))

        XCTAssertEqual(view.backgroundPackInvocationCount, afterFirst + 1, "A scale change must repack")
    }

    func testChangingMaxRowsRepacks() {
        let view = makeView()
        view.testSetCachedAlignedReads(stackedReads(count: 60))
        let region = GenomicRegion(chromosome: "chr1", start: 900, end: 2_000)
        let frame = makeFrame()

        let originalLimit = view.limitReadRowsSetting
        let originalMax = view.maxReadRowsSetting
        defer {
            view.limitReadRowsSetting = originalLimit
            view.maxReadRowsSetting = originalMax
        }

        view.limitReadRowsSetting = true
        view.maxReadRowsSetting = 10
        prepareAndDrain(view, region: region, frame: frame)
        let afterFirst = view.backgroundPackInvocationCount

        view.maxReadRowsSetting = 20
        _ = view.prepareDetachedReadLayout(region: region, frame: frame)

        XCTAssertEqual(view.backgroundPackInvocationCount, afterFirst + 1, "A max-rows change must repack")
    }

    func testPanningWithUnlimitedRowsReusesLayout() {
        let view = makeView()
        view.testSetCachedAlignedReads(stackedReads(count: 30))
        let frame = makeFrame()

        let originalLimit = view.limitReadRowsSetting
        defer { view.limitReadRowsSetting = originalLimit }
        view.limitReadRowsSetting = false

        prepareAndDrain(
            view,
            region: GenomicRegion(chromosome: "chr1", start: 900, end: 2_000),
            frame: frame
        )
        let afterFirst = view.backgroundPackInvocationCount

        // With no row cap every read is placed, so the prioritized region cannot
        // change the outcome and panning must not repack.
        _ = view.prepareDetachedReadLayout(
            region: GenomicRegion(chromosome: "chr1", start: 1_400, end: 2_500),
            frame: frame
        )

        XCTAssertEqual(
            view.backgroundPackInvocationCount, afterFirst,
            "With unlimited rows the prioritized region does not affect packing, so panning must reuse the layout"
        )
    }

    func testCachedLayoutMatchesAFreshPack() {
        let view = makeView()
        let reads = stackedReads(count: 30)
        view.testSetCachedAlignedReads(reads)
        let region = GenomicRegion(chromosome: "chr1", start: 900, end: 2_000)
        let frame = makeFrame()

        let (cached, cachedOverflow, maxRows) = prepareAndDrain(view, region: region, frame: frame)
        // Draw again to exercise the cache-hit path.
        let (reused, reusedOverflow, _) = view.prepareDetachedReadLayout(region: region, frame: frame)

        let (fresh, freshOverflow) = ReadTrackRenderer.packReads(
            reads.filter { $0.chromosome == region.chromosome },
            frame: frame,
            maxRows: maxRows,
            sortMode: .position,
            prioritizedRegion: region.start..<region.end
        )

        XCTAssertEqual(cached.map(\.row), fresh.map(\.row))
        XCTAssertEqual(cached.map(\.read.id), fresh.map(\.read.id))
        XCTAssertEqual(cachedOverflow, freshOverflow)
        XCTAssertEqual(reused.map(\.row), fresh.map(\.row), "Cache hit must be byte-identical to a fresh pack")
        XCTAssertEqual(reusedOverflow, freshOverflow)
    }

    // MARK: - 2. Cull by visible rows and x-range

    private let rowHeight: CGFloat = 6
    private let rowGap: CGFloat = 1

    func testVisibleRowRangeSkipsRowsScrolledAboveTheViewport() {
        let rect = CGRect(x: 0, y: 0, width: 800, height: 700)
        // Viewport shows content-space y 210..<350, i.e. rows 30..~50.
        let clip = CGRect(x: 0, y: 210, width: 800, height: 140)

        let range = ReadTrackCulling.visibleRowRange(
            rect: rect, clip: clip, rowCount: 100, rowHeight: rowHeight, rowGap: rowGap
        )

        XCTAssertGreaterThan(range.lowerBound, 0, "Rows above the viewport must be skipped")
        XCTAssertLessThan(range.upperBound, 100, "Rows below the viewport must be skipped")
        // Row r spans [r*7, r*7+6]; the first row intersecting y=210 is row 29.
        XCTAssertLessThanOrEqual(range.lowerBound, 30)
        XCTAssertGreaterThanOrEqual(range.upperBound, 50)
    }

    func testVisibleRowRangeCoversEveryRowWhenClipEqualsContent() {
        let rect = CGRect(x: 0, y: 0, width: 800, height: 10 * 7)
        let range = ReadTrackCulling.visibleRowRange(
            rect: rect, clip: rect, rowCount: 10, rowHeight: rowHeight, rowGap: rowGap
        )
        XCTAssertEqual(range, 0..<10)
    }

    func testVisibleRowRangeIsEmptyForAnEmptyLayout() {
        let rect = CGRect(x: 0, y: 0, width: 800, height: 100)
        let range = ReadTrackCulling.visibleRowRange(
            rect: rect, clip: rect, rowCount: 0, rowHeight: rowHeight, rowGap: rowGap
        )
        XCTAssertTrue(range.isEmpty)
    }

    func testVisibleRowRangeExcludesRowsWhoseBottomFallsPastTheContentRect() {
        // Legacy guard: a row was drawn only when y + readHeight <= rect.maxY.
        let rect = CGRect(x: 0, y: 0, width: 800, height: 20)
        let range = ReadTrackCulling.visibleRowRange(
            rect: rect, clip: CGRect(x: 0, y: 0, width: 800, height: 1_000),
            rowCount: 100, rowHeight: rowHeight, rowGap: rowGap
        )
        // Rows 0,1,2 fit (y=0,7,14 -> bottoms 6,13,20); row 3 (y=21) does not.
        XCTAssertEqual(range, 0..<3)
    }

    func testVisibleReadRangeExcludesReadsLeftAndRightOfTheWindow() {
        // Position-sorted, as packReads emits within a row.
        let reads = [
            makeRead(name: "far-left", position: 0, length: 50),      // ends 50
            makeRead(name: "left", position: 100, length: 50),         // ends 150
            makeRead(name: "inside", position: 500, length: 50),
            makeRead(name: "right", position: 5_000, length: 50),
        ]

        let range = ReadTrackCulling.visibleReadRange(
            in: reads, genomicStart: 400, genomicEnd: 600, maxReadSpan: 50
        )

        let names = range.map { reads[$0].name }
        XCTAssertTrue(names.contains("inside"))
        XCTAssertFalse(names.contains("far-left"), "Reads ending before the window must be excluded")
        XCTAssertFalse(names.contains("right"), "Reads starting after the window must be excluded")
    }

    func testVisibleReadRangeIncludesReadsOverlappingTheWindowEdge() {
        let reads = [
            makeRead(name: "straddles-left", position: 380, length: 50),  // 380..430
            makeRead(name: "inside", position: 500, length: 20),
            makeRead(name: "straddles-right", position: 590, length: 50), // 590..640
        ]

        let range = ReadTrackCulling.visibleReadRange(
            in: reads, genomicStart: 400, genomicEnd: 600, maxReadSpan: 50
        )
        let names = Set(range.map { reads[$0].name })

        XCTAssertTrue(names.contains("straddles-left"), "A read overlapping the left edge must be drawn")
        XCTAssertTrue(names.contains("straddles-right"), "A read overlapping the right edge must be drawn")
        XCTAssertTrue(names.contains("inside"))
    }

    func testVisibleReadRangeIsEmptyForEmptyInput() {
        XCTAssertTrue(
            ReadTrackCulling.visibleReadRange(in: [], genomicStart: 0, genomicEnd: 100, maxReadSpan: 10).isEmpty
        )
    }

    func testCullingSelectsTheSameReadsAsAFullScan() {
        // Property check: culling must never change which reads are drawn.
        var reads: [AlignedRead] = []
        for i in 0..<400 {
            reads.append(makeRead(name: "r\(i)", position: i * 25, length: 100))
        }
        reads.sort { $0.position < $1.position }

        let genomicStart = 2_000
        let genomicEnd = 4_000
        let maxSpan = 100

        let culled = Set(
            ReadTrackCulling.visibleReadRange(
                in: reads, genomicStart: genomicStart, genomicEnd: genomicEnd, maxReadSpan: maxSpan
            )
            .map { reads[$0].id }
            .filter { id in reads.first { $0.id == id }!.alignmentEnd > genomicStart }
        )

        let scanned = Set(
            reads.filter { $0.alignmentEnd > genomicStart && $0.position < genomicEnd }.map(\.id)
        )

        XCTAssertEqual(culled, scanned, "Culling must select exactly the reads a full scan would")
    }

    func testPackedReadLayoutBucketsRowsInPositionOrder() {
        let packed: [(row: Int, read: AlignedRead)] = [
            (0, makeRead(name: "a", position: 100)),
            (1, makeRead(name: "b", position: 150)),
            (0, makeRead(name: "c", position: 400)),
        ]
        let layout = PackedReadLayout(packedReads: packed)

        XCTAssertEqual(layout.rowCount, 2)
        XCTAssertEqual(layout.rows[0].map(\.name), ["a", "c"])
        XCTAssertEqual(layout.rows[1].map(\.name), ["b"])
        XCTAssertEqual(layout.maxReadSpan, 100)
    }

    // MARK: - 3. Precompute mismatch positions once per read

    func testMismatchCacheMatchesDirectMDTagParsing() {
        let reads = [
            makeRead(name: "a", position: 100, length: 10, mdTag: "3A2T3", sequence: "ACGTACGTAC"),
            makeRead(name: "b", position: 500, length: 10, mdTag: "10", sequence: "ACGTACGTAC"),
            makeRead(name: "c", position: 900, length: 10, mdTag: "5^AC5", sequence: "ACGTACGTAC"),
        ]

        let cache = ReadMismatchCache.build(for: reads)

        for read in reads {
            let expected = ReadTrackRenderer.mismatchPositionsFromMDTag(read.mdTag!, readStart: read.position)
            XCTAssertEqual(cache.positions(for: read), expected, "Cache must match the direct parse for \(read.name)")
        }
    }

    func testMismatchCacheReturnsNilForReadsWithoutAnMDTag() {
        let read = makeRead(name: "no-md", position: 100, length: 10, mdTag: nil)
        let cache = ReadMismatchCache.build(for: [read])

        XCTAssertNil(
            cache.positions(for: read),
            "A read with no MD tag must yield nil, matching read.mdTag.map { ... } semantics"
        )
    }

    func testMismatchCacheIsBuiltWhenReadsAreStoredAndReusedAcrossDraws() {
        let view = makeView()
        let reads = [
            makeRead(name: "a", position: 100, length: 10, mdTag: "3A6", sequence: "ACGTACGTAC"),
            makeRead(name: "b", position: 200, length: 10, mdTag: "5T4", sequence: "ACGTACGTAC"),
        ]

        view.testSetCachedAlignedReads(reads)
        XCTAssertEqual(
            view.testCachedReadMismatchCache?.count, 2,
            "Storing reads must precompute the mismatch cache"
        )

        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 1_000)
        let frame = makeFrame()
        _ = view.prepareDetachedReadLayout(region: region, frame: frame)
        _ = view.prepareDetachedReadLayout(region: region, frame: frame)

        // The cache instance must survive redraws untouched.
        XCTAssertEqual(view.testCachedReadMismatchCache?.count, 2)
        for read in reads {
            XCTAssertEqual(
                view.testCachedReadMismatchCache?.positions(for: read),
                ReadTrackRenderer.mismatchPositionsFromMDTag(read.mdTag!, readStart: read.position)
            )
        }
    }

    func testMismatchCacheIsInvalidatedWhenReadsChange() {
        let view = makeView()
        let first = [makeRead(name: "a", position: 100, length: 10, mdTag: "3A6", sequence: "ACGTACGTAC")]
        view.testSetCachedAlignedReads(first)
        XCTAssertEqual(view.testCachedReadMismatchCache?.count, 1)

        let second = [
            makeRead(name: "x", position: 700, length: 10, mdTag: "1C8", sequence: "ACGTACGTAC"),
            makeRead(name: "y", position: 800, length: 10, mdTag: "2G7", sequence: "ACGTACGTAC"),
        ]
        view.testSetCachedAlignedReads(second)

        XCTAssertEqual(view.testCachedReadMismatchCache?.count, 2, "A new read set must rebuild the cache")
        XCTAssertNil(
            view.testCachedReadMismatchCache?.positions(for: first[0]),
            "Stale reads must not survive in the cache"
        )
    }

    func testClearingReadsEmptiesTheMismatchCache() {
        let view = makeView()
        view.testSetCachedAlignedReads([
            makeRead(name: "a", position: 100, length: 10, mdTag: "3A6", sequence: "ACGTACGTAC")
        ])
        view.testSetCachedAlignedReads([])

        XCTAssertEqual(view.testCachedReadMismatchCache?.isEmpty, true)
    }

    // MARK: - Micro-benchmark (opt in via LUNGFISH_READ_RENDER_BENCH=1)

    func testHighDepthPackAndCullBenchmark() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LUNGFISH_READ_RENDER_BENCH"] == "1",
            "Set LUNGFISH_READ_RENDER_BENCH=1 to run the 200k-read timing benchmark"
        )

        let count = 200_000
        var reads: [AlignedRead] = []
        reads.reserveCapacity(count)
        for i in 0..<count {
            reads.append(makeRead(name: "r\(i)", position: (i % 20_000) * 5, length: 150, mdTag: "50A99"))
        }

        let view = makeView()
        let frame = makeFrame(start: 0, end: 100_000, pixelWidth: 1_400)
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 100_000)

        var clock = ContinuousClock().now
        view.testSetCachedAlignedReads(reads)
        let storeElapsed = ContinuousClock().now - clock

        clock = ContinuousClock().now
        let (packed, _, _) = view.prepareDetachedReadLayout(region: region, frame: frame)
        let firstPack = ContinuousClock().now - clock

        clock = ContinuousClock().now
        for _ in 0..<60 { _ = view.prepareDetachedReadLayout(region: region, frame: frame) }
        let sixtyCachedFrames = ContinuousClock().now - clock

        print("""
        [read-render-bench] reads=\(count) packed=\(packed.count) rows=\(view.testCachedPackedReadLayout?.rowCount ?? 0)
        [read-render-bench] store+mismatch-precompute: \(storeElapsed)
        [read-render-bench] first pack:                \(firstPack)
        [read-render-bench] 60 cached frames:          \(sixtyCachedFrames)
        [read-render-bench] pack invocations:          \(view.packInvocationCount)
        """)

        XCTAssertEqual(view.packInvocationCount, 1, "60 redraws must pack exactly once")
    }
}
