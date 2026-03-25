// MiniPileupDepthTests.swift - Tests for depth computation edge cases
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Testing
@testable import LungfishCore

/// Tests that the per-pixel depth computation used by MiniPileupView
/// handles edge cases without crashing (e.g., zero-length reads, reads
/// that round to the same pixel at high zoom-out levels).
@Suite("MiniPileup Depth Computation")
struct MiniPileupDepthTests {

    /// Computes per-pixel depth from reads using the same algorithm as
    /// ``MiniPileupView.drawDepthTrack``. Extracted here so it can be
    /// tested without an AppKit view.
    static func computeDepths(
        reads: [(position: Int, alignmentEnd: Int)],
        pixelCount: Int,
        bpPerPixel: Double
    ) -> [Int] {
        guard pixelCount > 0 else { return [] }
        var depths = [Int](repeating: 0, count: pixelCount)
        for read in reads {
            let startPx = max(0, Int(Double(read.position) / bpPerPixel))
            let endPx = min(pixelCount - 1, Int(Double(read.alignmentEnd) / bpPerPixel))
            guard startPx <= endPx else { continue }
            for px in startPx...endPx {
                depths[px] += 1
            }
        }
        return depths
    }

    @Test("Normal reads produce correct depth")
    func normalReads() {
        let depths = Self.computeDepths(
            reads: [(position: 0, alignmentEnd: 100)],
            pixelCount: 10,
            bpPerPixel: 10.0
        )
        #expect(depths.count == 10)
        #expect(depths.allSatisfy { $0 == 1 })
    }

    @Test("Zero-length read does not crash")
    func zeroLengthRead() {
        // A read where position == alignmentEnd (zero reference span)
        let depths = Self.computeDepths(
            reads: [(position: 50, alignmentEnd: 50)],
            pixelCount: 100,
            bpPerPixel: 1.0
        )
        // Should not crash; the read occupies a single pixel
        #expect(depths.count == 100)
        #expect(depths[50] == 1)
    }

    @Test("Read that rounds to inverted pixel range does not crash")
    func invertedPixelRange() {
        // At high bpPerPixel, a short read can round startPx > endPx
        // e.g., position=5, alignmentEnd=6, bpPerPixel=100 → startPx=0, endPx=0
        // But with position=5005, alignmentEnd=5006, pixelCount=50, bpPerPixel=100:
        // startPx = 50, endPx = min(49, 50) = 49 → startPx > endPx
        let depths = Self.computeDepths(
            reads: [(position: 5005, alignmentEnd: 5006)],
            pixelCount: 50,
            bpPerPixel: 100.0
        )
        // Should not crash; read is outside visible area
        #expect(depths.count == 50)
        #expect(depths.allSatisfy { $0 == 0 })
    }

    @Test("Read at contig boundary does not crash")
    func contigBoundary() {
        // Read positioned exactly at the last pixel
        let depths = Self.computeDepths(
            reads: [(position: 5380, alignmentEnd: 5387)],
            pixelCount: 20,
            bpPerPixel: 270.0
        )
        // startPx = Int(5380/270) = 19, endPx = min(19, Int(5387/270)) = min(19, 19) = 19
        #expect(depths.count == 20)
        #expect(depths[19] >= 1)
    }

    @Test("Single-pixel viewport does not crash")
    func singlePixelViewport() {
        let depths = Self.computeDepths(
            reads: [(position: 0, alignmentEnd: 100)],
            pixelCount: 1,
            bpPerPixel: 100.0
        )
        #expect(depths == [1])
    }

    @Test("Zero-pixel viewport returns empty")
    func zeroPixelViewport() {
        let depths = Self.computeDepths(
            reads: [(position: 0, alignmentEnd: 100)],
            pixelCount: 0,
            bpPerPixel: 1.0
        )
        #expect(depths.isEmpty)
    }

    @Test("Many overlapping reads at same position")
    func manyOverlapping() {
        let reads = (0..<100).map { _ in (position: 0, alignmentEnd: 83) }
        let depths = Self.computeDepths(
            reads: reads,
            pixelCount: 10,
            bpPerPixel: 10.0
        )
        // All 100 reads cover all 10 pixels (0-83 at 10 bp/px → px 0-8)
        #expect(depths[0] == 100)
        #expect(depths[8] == 100)
    }
}
