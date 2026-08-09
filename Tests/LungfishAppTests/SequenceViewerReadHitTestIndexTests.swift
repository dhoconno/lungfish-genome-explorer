// SequenceViewerReadHitTestIndexTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore

/// Parity coverage for the F1 fix: row-bucketed read hit-testing must return exactly the
/// same result as a full linear scan over `cachedPackedReads`, for both the bucket-building
/// helper (`bucketPackedReadsByRow`) and the indexed hit-test (`readInRow`).
@MainActor
final class SequenceViewerReadHitTestIndexTests: XCTestCase {

    // MARK: - Fixture

    /// Reference implementation mirroring the pre-fix linear scan in `readAtPoint`:
    /// `for (row, read) in cachedPackedReads where row == rowIndex { ... }`.
    private func linearScanHitTest(
        rowIndex: Int,
        packedReads: [(row: Int, read: AlignedRead)],
        atX x: CGFloat,
        frame: ReferenceFrame
    ) -> AlignedRead? {
        for (row, read) in packedReads where row == rowIndex {
            let startPx = frame.genomicToPixel(Double(read.position))
            let endPx = frame.genomicToPixel(Double(read.alignmentEnd))
            let readWidth = max(ReadTrackRenderer.minReadPixels, endPx - startPx)
            if x >= startPx && x <= startPx + readWidth {
                return read
            }
        }
        return nil
    }

    private func makeRead(name: String, position: Int, length: Int) -> AlignedRead {
        AlignedRead(
            name: name,
            flag: 0,
            chromosome: "chr1",
            position: position,
            mapq: 60,
            cigar: [CIGAROperation(op: .match, length: length)],
            sequence: String(repeating: "A", count: length),
            qualities: Array(repeating: 30, count: length)
        )
    }

    /// Builds a synthetic packed-read set spanning many rows, including:
    /// - dense rows with several non-overlapping reads
    /// - a row containing two reads packed back-to-back (adjacent, not overlapping —
    ///   packing never actually overlaps reads in the same row, but they can be pixel-adjacent)
    /// - at least one row deliberately left empty (no entries in cachedPackedReads for that row)
    private func makeSyntheticPackedReads() -> [(row: Int, read: AlignedRead)] {
        var packed: [(row: Int, read: AlignedRead)] = []

        // Row 0: several short reads spaced out.
        for i in 0..<5 {
            packed.append((row: 0, read: makeRead(name: "r0-\(i)", position: i * 100, length: 40)))
        }

        // Row 1: intentionally left empty (no reads packed here) — simulates a gap row.

        // Row 2: two reads placed back-to-back (adjacent boundaries, stresses the
        // "overlapping reads" / shared-edge case in horizontal hit-testing).
        packed.append((row: 2, read: makeRead(name: "r2-a", position: 0, length: 50)))
        packed.append((row: 2, read: makeRead(name: "r2-b", position: 50, length: 50)))

        // Row 3: dense pack of many short reads (stresses bucket correctness at scale).
        for i in 0..<50 {
            packed.append((row: 3, read: makeRead(name: "r3-\(i)", position: i * 20, length: 15)))
        }

        // Row 4: single very long read.
        packed.append((row: 4, read: makeRead(name: "r4-long", position: 0, length: 5000)))

        return packed
    }

    // MARK: - Bucket-building parity

    func testBucketPackedReadsByRowGroupsEveryReadUnderItsRow() {
        let packed = makeSyntheticPackedReads()
        let buckets = SequenceViewerView.bucketPackedReadsByRow(packed)

        // Every (row, read) pair from the source array must appear in the matching bucket.
        for (row, read) in packed {
            XCTAssertTrue(
                buckets[row]?.contains(where: { $0.id == read.id }) ?? false,
                "Read \(read.name) missing from bucket for row \(row)"
            )
        }

        // Bucket counts must match source counts per row.
        let expectedCounts = Dictionary(grouping: packed, by: \.row).mapValues(\.count)
        for (row, count) in expectedCounts {
            XCTAssertEqual(buckets[row]?.count, count, "Row \(row) bucket count mismatch")
        }

        // The intentionally-empty row must simply be absent (not an empty array vs missing key
        // distinction the caller needs to worry about — readInRow treats both as no hit).
        XCTAssertNil(buckets[1])
    }

    func testBucketPackedReadsByRowOnEmptyInputProducesEmptyBuckets() {
        let buckets = SequenceViewerView.bucketPackedReadsByRow([])
        XCTAssertTrue(buckets.isEmpty)
    }

    // MARK: - Hit-test parity (100 randomized points)

    func testIndexedHitTestMatchesLinearScanAcrossRandomizedPoints() {
        let packed = makeSyntheticPackedReads()
        let buckets = SequenceViewerView.bucketPackedReadsByRow(packed)
        let frame = ReferenceFrame(chromosome: "chr1", start: 0, end: 2000, pixelWidth: 2000)

        var rng = SeededRNG(seed: 42)
        let maxRow = (packed.map(\.row).max() ?? 0) + 1 // include one row beyond max (out of range)

        for _ in 0..<100 {
            let row = Int.random(in: -1...maxRow, using: &rng) // include -1 (invalid row)
            let x = CGFloat(Double.random(in: -50...2050, using: &rng))

            let expected = linearScanHitTest(rowIndex: row, packedReads: packed, atX: x, frame: frame)
            let actual = SequenceViewerView.readInRow(row, from: buckets, atX: x, frame: frame)

            XCTAssertEqual(
                actual?.id, expected?.id,
                "Mismatch at row=\(row) x=\(x): linear=\(expected?.name ?? "nil") indexed=\(actual?.name ?? "nil")"
            )
        }
    }

    func testIndexedHitTestMatchesLinearScanAtRowBoundaryPoints() {
        let packed = makeSyntheticPackedReads()
        let buckets = SequenceViewerView.bucketPackedReadsByRow(packed)
        let frame = ReferenceFrame(chromosome: "chr1", start: 0, end: 2000, pixelWidth: 2000)

        // Exact left/right edges of each read, plus the empty row (row 1) and one row past the end.
        var testPoints: [(row: Int, x: CGFloat)] = []
        for (row, read) in packed {
            let startPx = frame.genomicToPixel(Double(read.position))
            let endPx = frame.genomicToPixel(Double(read.alignmentEnd))
            testPoints.append((row, startPx)) // left edge
            testPoints.append((row, endPx))   // right edge
            testPoints.append((row, startPx - 1)) // just outside left
            testPoints.append((row, endPx + 1))   // just outside right
        }
        testPoints.append((1, 0))     // empty row
        testPoints.append((99, 0))    // row far beyond any packed data

        for point in testPoints {
            let expected = linearScanHitTest(rowIndex: point.row, packedReads: packed, atX: point.x, frame: frame)
            let actual = SequenceViewerView.readInRow(point.row, from: buckets, atX: point.x, frame: frame)
            XCTAssertEqual(
                actual?.id, expected?.id,
                "Boundary mismatch at row=\(point.row) x=\(point.x): linear=\(expected?.name ?? "nil") indexed=\(actual?.name ?? "nil")"
            )
        }
    }

    // MARK: - F2: single early bounds/row gate for mouseMoved's hit-test chain

    func testMouseMovedHitTestGateRejectsPointsOutsideViewBounds() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        // Above bounds, below bounds, left of bounds, right of bounds.
        XCTAssertFalse(SequenceViewerView.mouseMovedHitTestGate(point: NSPoint(x: 400, y: 601), viewBounds: bounds, annotationTrackY: 64))
        XCTAssertFalse(SequenceViewerView.mouseMovedHitTestGate(point: NSPoint(x: 400, y: -1), viewBounds: bounds, annotationTrackY: 64))
        XCTAssertFalse(SequenceViewerView.mouseMovedHitTestGate(point: NSPoint(x: -1, y: 300), viewBounds: bounds, annotationTrackY: 64))
        XCTAssertFalse(SequenceViewerView.mouseMovedHitTestGate(point: NSPoint(x: 801, y: 300), viewBounds: bounds, annotationTrackY: 64))
    }

    func testMouseMovedHitTestGateRejectsPointsAboveAnnotationTrack() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertFalse(SequenceViewerView.mouseMovedHitTestGate(point: NSPoint(x: 400, y: 63), viewBounds: bounds, annotationTrackY: 64))
    }

    func testMouseMovedHitTestGateAcceptsPointsWithinBoundsAtOrBelowAnnotationTrack() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertTrue(SequenceViewerView.mouseMovedHitTestGate(point: NSPoint(x: 400, y: 64), viewBounds: bounds, annotationTrackY: 64))
        XCTAssertTrue(SequenceViewerView.mouseMovedHitTestGate(point: NSPoint(x: 400, y: 500), viewBounds: bounds, annotationTrackY: 64))
        // Bounds edges are inclusive on the low end, exclusive on the high end (NSRect.contains semantics).
        XCTAssertTrue(SequenceViewerView.mouseMovedHitTestGate(point: NSPoint(x: 0, y: 64), viewBounds: bounds, annotationTrackY: 64))
    }

    func testIndexedHitTestMatchesLinearScanForOverlappingReadsInSameRow() {
        // A row where two reads' pixel spans overlap (can occur when minReadPixels padding
        // widens a short read past its neighbor's true genomic start).
        var packed: [(row: Int, read: AlignedRead)] = []
        packed.append((row: 0, read: makeRead(name: "overlap-a", position: 0, length: 1)))
        packed.append((row: 0, read: makeRead(name: "overlap-b", position: 1, length: 1)))
        let buckets = SequenceViewerView.bucketPackedReadsByRow(packed)

        // Very zoomed-out frame so 1bp reads are sub-pixel and minReadPixels padding
        // forces overlapping screen rects.
        let frame = ReferenceFrame(chromosome: "chr1", start: 0, end: 100_000, pixelWidth: 200)

        var rng = SeededRNG(seed: 7)
        for _ in 0..<100 {
            let x = CGFloat(Double.random(in: -5...20, using: &rng))
            let expected = linearScanHitTest(rowIndex: 0, packedReads: packed, atX: x, frame: frame)
            let actual = SequenceViewerView.readInRow(0, from: buckets, atX: x, frame: frame)
            XCTAssertEqual(actual?.id, expected?.id, "Overlap mismatch at x=\(x)")
        }
    }
}

/// Small deterministic PRNG so randomized parity tests are reproducible across runs.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
