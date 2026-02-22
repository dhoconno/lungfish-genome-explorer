// ReadTrackRendererTests.swift - Tests for alignment read track rendering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class ReadTrackRendererTests: XCTestCase {

    // MARK: - Test Helpers

    /// Creates a simple forward read at a given position with a match-only CIGAR.
    private func makeRead(
        name: String = "read1",
        flag: UInt16 = 99,   // paired, proper pair, mate reverse, first in pair
        chromosome: String = "chr1",
        position: Int = 100,
        mapq: UInt8 = 60,
        cigarLength: Int = 150,
        sequence: String? = nil
    ) -> AlignedRead {
        let cigar = [CIGAROperation(op: .match, length: cigarLength)]
        let seq = sequence ?? String(repeating: "A", count: cigarLength)
        return AlignedRead(
            name: name,
            flag: flag,
            chromosome: chromosome,
            position: position,
            mapq: mapq,
            cigar: cigar,
            sequence: seq,
            qualities: Array(repeating: 30, count: seq.count)
        )
    }

    /// Creates a ReferenceFrame for testing.
    private func makeFrame(
        start: Double = 0,
        end: Double = 10000,
        pixelWidth: Int = 1000
    ) -> ReferenceFrame {
        ReferenceFrame(
            chromosome: "chr1",
            start: start,
            end: end,
            pixelWidth: pixelWidth
        )
    }

    // MARK: - Zoom Tier Detection

    func testZoomTierCoverageAboveThreshold() {
        // > 10 bp/px → coverage
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: 11.0), .coverage)
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: 100.0), .coverage)
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: 1000.0), .coverage)
    }

    func testZoomTierCoverageAtThreshold() {
        // Exactly at threshold: > 10 → coverage
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: 10.001), .coverage)
    }

    func testZoomTierPackedBetweenThresholds() {
        // 0.5 < scale <= 10 → packed
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: 10.0), .packed)
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: 5.0), .packed)
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: 1.0), .packed)
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: 0.51), .packed)
    }

    func testZoomTierBaseAtAndBelowThreshold() {
        // <= 0.5 → base
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: 0.5), .base)
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: 0.1), .base)
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: 0.01), .base)
    }

    func testZoomTierBoundaryValues() {
        // Test the exact boundary between packed and base
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: 0.500001), .packed)
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: 0.5), .base)
    }

    // MARK: - Total Height Calculation

    func testTotalHeightCoverage() {
        // Coverage tier always returns the fixed coverage track height
        XCTAssertEqual(
            ReadTrackRenderer.totalHeight(rowCount: 0, tier: .coverage),
            ReadTrackRenderer.coverageTrackHeight
        )
        XCTAssertEqual(
            ReadTrackRenderer.totalHeight(rowCount: 50, tier: .coverage),
            ReadTrackRenderer.coverageTrackHeight
        )
    }

    func testTotalHeightPacked() {
        let rowCount = 10
        let expected = CGFloat(rowCount) * (ReadTrackRenderer.packedReadHeight + ReadTrackRenderer.rowGap)
        XCTAssertEqual(ReadTrackRenderer.totalHeight(rowCount: rowCount, tier: .packed), expected)
    }

    func testTotalHeightBase() {
        let rowCount = 5
        let expected = CGFloat(rowCount) * (ReadTrackRenderer.baseReadHeight + ReadTrackRenderer.rowGap)
        XCTAssertEqual(ReadTrackRenderer.totalHeight(rowCount: rowCount, tier: .base), expected)
    }

    func testTotalHeightZeroRows() {
        XCTAssertEqual(ReadTrackRenderer.totalHeight(rowCount: 0, tier: .packed), 0)
        XCTAssertEqual(ReadTrackRenderer.totalHeight(rowCount: 0, tier: .base), 0)
    }

    func testTotalHeightSingleRow() {
        let packedExpected = ReadTrackRenderer.packedReadHeight + ReadTrackRenderer.rowGap
        XCTAssertEqual(ReadTrackRenderer.totalHeight(rowCount: 1, tier: .packed), packedExpected)

        let baseExpected = ReadTrackRenderer.baseReadHeight + ReadTrackRenderer.rowGap
        XCTAssertEqual(ReadTrackRenderer.totalHeight(rowCount: 1, tier: .base), baseExpected)
    }

    // MARK: - Pack Reads

    func testPackReadsEmptyInput() {
        let frame = makeFrame()
        let (packed, overflow) = ReadTrackRenderer.packReads([], frame: frame)
        XCTAssertTrue(packed.isEmpty)
        XCTAssertEqual(overflow, 0)
    }

    func testPackReadsSingleRead() {
        let frame = makeFrame(start: 0, end: 10000, pixelWidth: 1000)
        let read = makeRead(position: 100, cigarLength: 150)
        let (packed, overflow) = ReadTrackRenderer.packReads([read], frame: frame)

        XCTAssertEqual(packed.count, 1)
        XCTAssertEqual(overflow, 0)
        XCTAssertEqual(packed[0].row, 0)
        XCTAssertEqual(packed[0].read.name, "read1")
    }

    func testPackReadsNonOverlappingSameRow() {
        // Two non-overlapping reads should go in the same row
        let frame = makeFrame(start: 0, end: 10000, pixelWidth: 1000)
        // scale = 10 bp/px, read 1 covers 100-250 (15 px), read 2 covers 1000-1150 (15 px)
        let read1 = makeRead(name: "r1", position: 100, cigarLength: 150)
        let read2 = makeRead(name: "r2", position: 1000, cigarLength: 150)

        let (packed, overflow) = ReadTrackRenderer.packReads([read1, read2], frame: frame)
        XCTAssertEqual(packed.count, 2)
        XCTAssertEqual(overflow, 0)

        // Both should be in row 0 since they don't overlap in pixel space
        let rows = packed.map(\.row)
        XCTAssertTrue(rows.allSatisfy { $0 == 0 })
    }

    func testPackReadsOverlappingDifferentRows() {
        // Overlapping reads should be placed in different rows
        // Scale: 1 bp/px (1000 bp over 1000 px)
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 1000)
        let read1 = makeRead(name: "r1", position: 100, cigarLength: 150)
        let read2 = makeRead(name: "r2", position: 120, cigarLength: 150)

        let (packed, overflow) = ReadTrackRenderer.packReads([read1, read2], frame: frame)
        XCTAssertEqual(packed.count, 2)
        XCTAssertEqual(overflow, 0)

        let rows = Set(packed.map(\.row))
        XCTAssertEqual(rows.count, 2, "Overlapping reads should be on different rows")
    }

    func testPackReadsOverflowWhenTooMany() {
        // Create more reads than maxRows allows
        let maxRows = 3
        // Scale: 1 bp/px so reads are wide enough to render
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 1000)

        // Place 5 fully overlapping reads at the same position
        var reads: [AlignedRead] = []
        for i in 0..<5 {
            reads.append(makeRead(name: "r\(i)", position: 100, cigarLength: 150))
        }

        let (packed, overflow) = ReadTrackRenderer.packReads(reads, frame: frame, maxRows: maxRows)
        XCTAssertEqual(packed.count, maxRows)
        XCTAssertEqual(overflow, 2, "2 reads should overflow with maxRows=3 and 5 overlapping reads")
    }

    func testPackReadsFiltersTooSmallReads() {
        // Reads that are less than minReadPixels wide should be filtered out
        // scale = 100 bp/px (100000 bp / 1000 px), so a 150bp read is 1.5px < minReadPixels (2)
        let frame = makeFrame(start: 0, end: 100000, pixelWidth: 1000)
        let read = makeRead(position: 100, cigarLength: 150)

        let (packed, overflow) = ReadTrackRenderer.packReads([read], frame: frame)
        XCTAssertTrue(packed.isEmpty, "A read smaller than minReadPixels should be skipped")
        XCTAssertEqual(overflow, 0, "Filtered reads should not count as overflow")
    }

    func testPackReadsSortsByPosition() {
        // Pack should work even if reads are given out of order
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 1000)
        let read1 = makeRead(name: "r_later", position: 500, cigarLength: 100)
        let read2 = makeRead(name: "r_earlier", position: 100, cigarLength: 100)

        let (packed, _) = ReadTrackRenderer.packReads([read1, read2], frame: frame)

        // Both should be packed (non-overlapping at these positions)
        XCTAssertEqual(packed.count, 2)

        // The first packed read should be the earlier one
        XCTAssertEqual(packed[0].read.name, "r_earlier")
        XCTAssertEqual(packed[1].read.name, "r_later")
    }

    func testPackReadsMaxRowsDefault() {
        // Default maxRows should be 75
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 1000)
        // Create 76 overlapping reads
        var reads: [AlignedRead] = []
        for i in 0..<76 {
            reads.append(makeRead(name: "r\(i)", position: 100, cigarLength: 150))
        }

        let (packed, overflow) = ReadTrackRenderer.packReads(reads, frame: frame)
        XCTAssertEqual(packed.count, 75)
        XCTAssertEqual(overflow, 1)
    }

    // MARK: - Layout Constants

    func testLayoutConstants() {
        // Verify the expected constants haven't changed unexpectedly
        XCTAssertEqual(ReadTrackRenderer.packedReadHeight, 6)
        XCTAssertEqual(ReadTrackRenderer.baseReadHeight, 14)
        XCTAssertEqual(ReadTrackRenderer.rowGap, 1)
        XCTAssertEqual(ReadTrackRenderer.coverageTrackHeight, 60)
        XCTAssertEqual(ReadTrackRenderer.maxReadRows, 75)
        XCTAssertEqual(ReadTrackRenderer.minReadPixels, 2)
    }

    func testZoomThresholdConstants() {
        XCTAssertEqual(ReadTrackRenderer.coverageThresholdBpPerPx, 10)
        XCTAssertEqual(ReadTrackRenderer.baseThresholdBpPerPx, 0.5)
    }

    // MARK: - ReferenceFrame Extension

    func testGenomicToPixel() {
        let frame = makeFrame(start: 1000, end: 2000, pixelWidth: 1000)
        // scale = (2000-1000)/1000 = 1 bp/px
        // genomicToPixel(pos) = (pos - start) / scale

        XCTAssertEqual(frame.genomicToPixel(1000), 0, accuracy: 0.01)
        XCTAssertEqual(frame.genomicToPixel(1500), 500, accuracy: 0.01)
        XCTAssertEqual(frame.genomicToPixel(2000), 1000, accuracy: 0.01)
    }

    func testGenomicToPixelWithDifferentScale() {
        // 10000 bp over 500 px = 20 bp/px
        let frame = makeFrame(start: 0, end: 10000, pixelWidth: 500)
        // genomicToPixel(5000) = (5000-0) / 20 = 250
        XCTAssertEqual(frame.genomicToPixel(5000), 250, accuracy: 0.01)
    }

    // MARK: - AlignedRead Properties Used by Renderer

    func testAlignedReadAlignmentEnd() {
        let read = makeRead(position: 100, cigarLength: 150)
        XCTAssertEqual(read.alignmentEnd, 250) // 100 + 150
    }

    func testAlignedReadIsReverse() {
        // Flag 99 = 0x63: paired + proper_pair + mate_reverse + first_in_pair → not reverse
        let forwardRead = makeRead(flag: 99)
        XCTAssertFalse(forwardRead.isReverse)

        // Flag 147 = 0x93: paired + proper_pair + reverse + second_in_pair
        let reverseRead = makeRead(flag: 147)
        XCTAssertTrue(reverseRead.isReverse)
    }

    func testAlignedReadWithDeletion() {
        // 50M5D100M → referenceLength = 50 + 5 + 100 = 155
        let cigar = [
            CIGAROperation(op: .match, length: 50),
            CIGAROperation(op: .deletion, length: 5),
            CIGAROperation(op: .match, length: 100)
        ]
        let read = AlignedRead(
            name: "r1", flag: 99, chromosome: "chr1", position: 100,
            mapq: 60, cigar: cigar,
            sequence: String(repeating: "A", count: 150),
            qualities: Array(repeating: 30, count: 150)
        )
        XCTAssertEqual(read.alignmentEnd, 255) // 100 + 155
    }

    func testAlignedReadWithInsertion() {
        // 50M3I97M → referenceLength = 50 + 97 = 147
        let cigar = [
            CIGAROperation(op: .match, length: 50),
            CIGAROperation(op: .insertion, length: 3),
            CIGAROperation(op: .match, length: 97)
        ]
        let read = AlignedRead(
            name: "r1", flag: 99, chromosome: "chr1", position: 100,
            mapq: 60, cigar: cigar,
            sequence: String(repeating: "A", count: 150),
            qualities: Array(repeating: 30, count: 150)
        )
        XCTAssertEqual(read.alignmentEnd, 247) // 100 + 147
        XCTAssertEqual(read.insertions.count, 1)
        XCTAssertEqual(read.insertions[0].position, 150) // refPos after 50M
        XCTAssertEqual(read.insertions[0].bases.count, 3)
    }

    // MARK: - Drawing Smoke Tests (verifies no crash, not visual output)

    func testDrawCoverageDoesNotCrash() {
        let frame = makeFrame(start: 0, end: 10000, pixelWidth: 200)
        let reads = (0..<20).map { i in
            makeRead(name: "r\(i)", position: i * 100, cigarLength: 150)
        }

        // Create a bitmap context
        let width = 200
        let height = 60
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        ReadTrackRenderer.drawCoverage(reads: reads, frame: frame, context: context, rect: rect)
        // If we reach here, no crash occurred
    }

    func testDrawPackedReadsDoesNotCrash() {
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 500)
        let reads = (0..<10).map { i in
            makeRead(name: "r\(i)", position: i * 50, cigarLength: 100)
        }

        let (packed, overflow) = ReadTrackRenderer.packReads(reads, frame: frame)

        let width = 500
        let height = 200
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        ReadTrackRenderer.drawPackedReads(
            packedReads: packed, overflow: overflow,
            frame: frame, context: context, rect: rect
        )
    }

    func testDrawBaseReadsDoesNotCrash() {
        // Scale < 0.5 bp/px for base tier
        let frame = makeFrame(start: 0, end: 200, pixelWidth: 1000)
        let read = makeRead(
            position: 50, cigarLength: 50,
            sequence: "ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTAC"
                    + "G" // 50 bases
        )

        let (packed, overflow) = ReadTrackRenderer.packReads([read], frame: frame)

        let width = 1000
        let height = 100
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        ReadTrackRenderer.drawBaseReads(
            packedReads: packed, overflow: overflow,
            frame: frame, referenceSequence: nil, referenceStart: 0,
            context: context, rect: rect
        )
    }

    func testDrawCoverageEmptyReads() {
        let frame = makeFrame()
        let width = 200
        let height = 60
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        ReadTrackRenderer.drawCoverage(reads: [], frame: frame, context: context, rect: rect)
        // Should not crash with empty reads
    }

    func testDrawPackedWithOverflow() {
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 500)
        // Create enough overlapping reads to exceed maxRows=3
        var reads: [AlignedRead] = []
        for i in 0..<5 {
            reads.append(makeRead(name: "r\(i)", position: 100, cigarLength: 150))
        }

        let (packed, overflow) = ReadTrackRenderer.packReads(reads, frame: frame, maxRows: 3)
        XCTAssertEqual(overflow, 2)

        let width = 500
        let height = 200
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        ReadTrackRenderer.drawPackedReads(
            packedReads: packed, overflow: overflow,
            frame: frame, context: context, rect: rect
        )
        // Should draw the overflow indicator bar without crash
    }

    func testDrawCoverageZeroWidthRect() {
        let frame = makeFrame()
        let context = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Zero-width rect should return early without crash
        let rect = CGRect(x: 0, y: 0, width: 0, height: 60)
        ReadTrackRenderer.drawCoverage(reads: [makeRead()], frame: frame, context: context, rect: rect)
    }

    // MARK: - Strand-Based Read Colors

    func testForwardAndReverseReadsDifferentColors() {
        // Just verify the color constants are distinct
        XCTAssertNotEqual(
            ReadTrackRenderer.forwardReadColor,
            ReadTrackRenderer.reverseReadColor
        )
        XCTAssertNotEqual(
            ReadTrackRenderer.forwardCoverageColor,
            ReadTrackRenderer.reverseCoverageColor
        )
    }

    // MARK: - Mixed Forward/Reverse Read Packing

    func testPackReadsMixedStrands() {
        // Forward and reverse reads at same position should pack into different rows
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 1000)
        let forwardRead = makeRead(name: "fwd", flag: 99, position: 100, cigarLength: 150)
        let reverseRead = makeRead(name: "rev", flag: 147, position: 100, cigarLength: 150)

        let (packed, overflow) = ReadTrackRenderer.packReads([forwardRead, reverseRead], frame: frame)
        XCTAssertEqual(packed.count, 2)
        XCTAssertEqual(overflow, 0)

        // They overlap, so should be on different rows
        let rows = Set(packed.map(\.row))
        XCTAssertEqual(rows.count, 2)
    }

    // MARK: - Display Settings

    func testDisplaySettingsDefaultValues() {
        let settings = ReadTrackRenderer.DisplaySettings()
        XCTAssertTrue(settings.showMismatches)
        XCTAssertTrue(settings.showSoftClips)
        XCTAssertTrue(settings.showIndels)
    }

    func testDisplaySettingsCustomValues() {
        let settings = ReadTrackRenderer.DisplaySettings(
            showMismatches: false, showSoftClips: true, showIndels: false
        )
        XCTAssertFalse(settings.showMismatches)
        XCTAssertTrue(settings.showSoftClips)
        XCTAssertFalse(settings.showIndels)
    }

    // MARK: - Mismatch Color Constants

    func testMismatchColorConstantsExist() {
        // Verify the new color constants are present
        XCTAssertNotNil(ReadTrackRenderer.mismatchTickColor)
        XCTAssertNotNil(ReadTrackRenderer.softClipColor)
    }

    // MARK: - Packed Mode Rendering with Reference Sequence

    func testDrawPackedReadsWithMismatchesDoesNotCrash() {
        // Scale: 2 bp/px (packed mode range)
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 500)
        // Reference is all As, read has mismatches at known positions
        let refSeq = String(repeating: "A", count: 1000)
        var readSeqChars = Array(repeating: Character("A"), count: 100)
        readSeqChars[10] = "T"  // mismatch at position 110
        readSeqChars[30] = "G"  // mismatch at position 130
        readSeqChars[50] = "C"  // mismatch at position 150
        let readSeq = String(readSeqChars)

        let read = AlignedRead(
            name: "mismatch_read", flag: 99, chromosome: "chr1", position: 100,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 100)],
            sequence: readSeq, qualities: Array(repeating: 30, count: 100)
        )

        let (packed, overflow) = ReadTrackRenderer.packReads([read], frame: frame)
        let width = 500, height = 100
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let settings = ReadTrackRenderer.DisplaySettings(showMismatches: true, showSoftClips: true, showIndels: true)

        ReadTrackRenderer.drawPackedReads(
            packedReads: packed, overflow: overflow, frame: frame,
            referenceSequence: refSeq, referenceStart: 0, settings: settings,
            context: context, rect: rect
        )
        // No crash = success
    }

    func testDrawPackedReadsWithMismatchesDisabledDoesNotCrash() {
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 500)
        let refSeq = String(repeating: "A", count: 1000)
        let read = makeRead(position: 100, cigarLength: 100)

        let (packed, overflow) = ReadTrackRenderer.packReads([read], frame: frame)
        let width = 500, height = 100
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let settings = ReadTrackRenderer.DisplaySettings(showMismatches: false, showSoftClips: false, showIndels: false)

        ReadTrackRenderer.drawPackedReads(
            packedReads: packed, overflow: overflow, frame: frame,
            referenceSequence: refSeq, referenceStart: 0, settings: settings,
            context: context, rect: rect
        )
    }

    func testDrawPackedReadsWithoutReferenceSequence() {
        // When no reference sequence is available, mismatches should be skipped silently
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 500)
        let read = makeRead(position: 100, cigarLength: 100)

        let (packed, overflow) = ReadTrackRenderer.packReads([read], frame: frame)
        let width = 500, height = 100
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        // No referenceSequence → nil, should skip mismatch drawing gracefully
        ReadTrackRenderer.drawPackedReads(
            packedReads: packed, overflow: overflow, frame: frame,
            referenceSequence: nil, referenceStart: 0,
            settings: ReadTrackRenderer.DisplaySettings(showMismatches: true),
            context: context, rect: rect
        )
    }

    // MARK: - Soft Clip Rendering

    func testDrawPackedReadsWithSoftClipsDoesNotCrash() {
        // Read with leading and trailing soft clips: 5S90M5S
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 500)
        let cigar = [
            CIGAROperation(op: .softClip, length: 5),
            CIGAROperation(op: .match, length: 90),
            CIGAROperation(op: .softClip, length: 5),
        ]
        let read = AlignedRead(
            name: "clipped", flag: 99, chromosome: "chr1", position: 100,
            mapq: 60, cigar: cigar,
            sequence: String(repeating: "A", count: 100),
            qualities: Array(repeating: 30, count: 100)
        )

        let (packed, overflow) = ReadTrackRenderer.packReads([read], frame: frame)
        let width = 500, height = 100
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        ReadTrackRenderer.drawPackedReads(
            packedReads: packed, overflow: overflow, frame: frame,
            settings: ReadTrackRenderer.DisplaySettings(showSoftClips: true),
            context: context, rect: rect
        )
    }

    func testDrawPackedReadsWithSoftClipsDisabled() {
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 500)
        let cigar = [
            CIGAROperation(op: .softClip, length: 5),
            CIGAROperation(op: .match, length: 90),
            CIGAROperation(op: .softClip, length: 5),
        ]
        let read = AlignedRead(
            name: "clipped", flag: 99, chromosome: "chr1", position: 100,
            mapq: 60, cigar: cigar,
            sequence: String(repeating: "A", count: 100),
            qualities: Array(repeating: 30, count: 100)
        )

        let (packed, overflow) = ReadTrackRenderer.packReads([read], frame: frame)
        let width = 500, height = 100
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        ReadTrackRenderer.drawPackedReads(
            packedReads: packed, overflow: overflow, frame: frame,
            settings: ReadTrackRenderer.DisplaySettings(showSoftClips: false),
            context: context, rect: rect
        )
    }

    // MARK: - Base Mode with Display Settings

    func testDrawBaseReadsWithSettingsDoesNotCrash() {
        let frame = makeFrame(start: 0, end: 200, pixelWidth: 1000)
        let read = makeRead(
            position: 50, cigarLength: 50,
            sequence: String(repeating: "ACGT", count: 12) + "AC" // 50 bases
        )
        let refSeq = String(repeating: "A", count: 200)

        let (packed, overflow) = ReadTrackRenderer.packReads([read], frame: frame)
        let width = 1000, height = 100
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let settings = ReadTrackRenderer.DisplaySettings(showMismatches: true, showSoftClips: true, showIndels: true)

        ReadTrackRenderer.drawBaseReads(
            packedReads: packed, overflow: overflow, frame: frame,
            referenceSequence: refSeq, referenceStart: 0, settings: settings,
            context: context, rect: rect
        )
    }

    func testDrawBaseReadsWithAllDisabled() {
        let frame = makeFrame(start: 0, end: 200, pixelWidth: 1000)
        let cigar = [
            CIGAROperation(op: .softClip, length: 5),
            CIGAROperation(op: .match, length: 40),
            CIGAROperation(op: .insertion, length: 3),
            CIGAROperation(op: .match, length: 10),
            CIGAROperation(op: .deletion, length: 2),
            CIGAROperation(op: .match, length: 5),
            CIGAROperation(op: .softClip, length: 5),
        ]
        let read = AlignedRead(
            name: "complex", flag: 99, chromosome: "chr1", position: 50,
            mapq: 60, cigar: cigar,
            sequence: String(repeating: "A", count: 68), // 5+40+3+10+5+5 = 68
            qualities: Array(repeating: 30, count: 68)
        )
        let refSeq = String(repeating: "A", count: 200)

        let (packed, overflow) = ReadTrackRenderer.packReads([read], frame: frame)
        let width = 1000, height = 100
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let settings = ReadTrackRenderer.DisplaySettings(showMismatches: false, showSoftClips: false, showIndels: false)

        ReadTrackRenderer.drawBaseReads(
            packedReads: packed, overflow: overflow, frame: frame,
            referenceSequence: refSeq, referenceStart: 0, settings: settings,
            context: context, rect: rect
        )
    }

    // MARK: - Mismatch Detection Logic

    func testForEachAlignedBaseDetectsMismatches() {
        // Read sequence "ACGTA" at position 0 with reference "AAGAA"
        // Mismatches at positions 1 (C vs A), 2 (G vs G) — match, 3 (T vs A)
        let read = AlignedRead(
            name: "test", flag: 0, chromosome: "chr1", position: 0,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 5)],
            sequence: "ACGTA", qualities: []
        )
        let reference = "AAGAA"
        let refChars = Array(reference)

        var mismatches: [(Int, Character, Character)] = []
        read.forEachAlignedBase { readBase, refPos, _ in
            let readChar = Character(String(readBase).uppercased())
            if refPos < refChars.count {
                let refChar = refChars[refPos]
                if readChar != refChar {
                    mismatches.append((refPos, readChar, refChar))
                }
            }
        }

        XCTAssertEqual(mismatches.count, 2)
        XCTAssertEqual(mismatches[0].0, 1) // position 1: C vs A
        XCTAssertEqual(mismatches[0].1, "C")
        XCTAssertEqual(mismatches[1].0, 3) // position 3: T vs A
        XCTAssertEqual(mismatches[1].1, "T")
    }

    func testForEachAlignedBaseSkipsDeletions() {
        // 3M2D3M — deletions don't yield read bases
        let read = AlignedRead(
            name: "test", flag: 0, chromosome: "chr1", position: 0,
            mapq: 60, cigar: [
                CIGAROperation(op: .match, length: 3),
                CIGAROperation(op: .deletion, length: 2),
                CIGAROperation(op: .match, length: 3),
            ],
            sequence: "AAATTT", qualities: []
        )

        var alignedPositions: [Int] = []
        read.forEachAlignedBase { _, refPos, _ in
            alignedPositions.append(refPos)
        }

        // Should yield: 0,1,2 (3M), skip 3,4 (2D), then 5,6,7 (3M)
        XCTAssertEqual(alignedPositions, [0, 1, 2, 5, 6, 7])
    }

    func testSoftClipPositionsInForEachAlignedBase() {
        // 3S5M2S — soft clips don't consume reference
        let read = AlignedRead(
            name: "test", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: [
                CIGAROperation(op: .softClip, length: 3),
                CIGAROperation(op: .match, length: 5),
                CIGAROperation(op: .softClip, length: 2),
            ],
            sequence: "AAACCCCCGG", qualities: []
        )

        var matchPositions: [Int] = []
        read.forEachAlignedBase { _, refPos, op in
            if op == .match {
                matchPositions.append(refPos)
            }
        }

        // Match bases should be at 100-104
        XCTAssertEqual(matchPositions, [100, 101, 102, 103, 104])
    }

    // MARK: - Downsample Tests

    func testDownsampleBelowThresholdReturnsAll() {
        let reads = (0..<100).map { i in makeRead(name: "r\(i)", position: i * 100) }
        let (result, totalCount) = ReadTrackRenderer.downsample(reads, maxReads: 200)
        XCTAssertEqual(result.count, 100, "Below threshold: all reads returned")
        XCTAssertEqual(totalCount, 100)
    }

    func testDownsampleReducesCount() {
        let reads = (0..<1000).map { i in makeRead(name: "r\(i)", position: i * 10) }
        let maxReads = 100
        let (result, totalCount) = ReadTrackRenderer.downsample(reads, maxReads: maxReads)
        XCTAssertEqual(result.count, maxReads, "Should downsample to exactly maxReads")
        XCTAssertEqual(totalCount, 1000)
    }

    func testDownsamplePreservesStrandBalance() {
        // Create 500 forward + 500 reverse reads
        var reads: [AlignedRead] = []
        for i in 0..<500 {
            reads.append(makeRead(name: "fwd\(i)", flag: 99, position: i * 10)) // forward
        }
        for i in 0..<500 {
            reads.append(makeRead(name: "rev\(i)", flag: 147, position: i * 10)) // reverse
        }
        reads.shuffle()

        let (result, totalCount) = ReadTrackRenderer.downsample(reads, maxReads: 200)
        XCTAssertEqual(totalCount, 1000)
        XCTAssertEqual(result.count, 200)

        // Check strand balance (should be roughly 50/50 since input is 50/50)
        let forwardCount = result.filter { !$0.isReverse }.count
        let reverseCount = result.filter { $0.isReverse }.count
        XCTAssertTrue(forwardCount > 60, "Forward reads should be well represented: got \(forwardCount)")
        XCTAssertTrue(reverseCount > 60, "Reverse reads should be well represented: got \(reverseCount)")
    }

    func testDownsampleResultIsSortedByPosition() {
        let reads = (0..<500).map { i in makeRead(name: "r\(i)", position: Int.random(in: 0..<10000)) }
        let (result, _) = ReadTrackRenderer.downsample(reads, maxReads: 100)

        for i in 1..<result.count {
            XCTAssertGreaterThanOrEqual(
                result[i].position, result[i - 1].position,
                "Result should be sorted by position"
            )
        }
    }

    func testDownsampleEdgeCaseExactThreshold() {
        let reads = (0..<100).map { i in makeRead(name: "r\(i)", position: i * 10) }
        let (result, totalCount) = ReadTrackRenderer.downsample(reads, maxReads: 100)
        XCTAssertEqual(result.count, 100, "Exactly at threshold: all reads returned")
        XCTAssertEqual(totalCount, 100)
    }

    func testDownsampleEmptyInput() {
        let (result, totalCount) = ReadTrackRenderer.downsample([], maxReads: 100)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(totalCount, 0)
    }

    // MARK: - Read Colors Tests

    func testReadColorsStrandMode() {
        let forward = makeRead(flag: 99) // forward
        let reverse = makeRead(flag: 147) // reverse

        let (fwdFill, _) = ReadTrackRenderer.readColors(for: forward, colorMode: .strand, alpha: 1.0)
        let (revFill, _) = ReadTrackRenderer.readColors(for: reverse, colorMode: .strand, alpha: 1.0)

        // Forward and reverse should produce different colors
        XCTAssertNotEqual(fwdFill, revFill, "Forward and reverse should have different fill colors")
    }

    func testReadColorsInsertSizeMode() {
        // Normal insert size
        let normal = AlignedRead(
            name: "r1", flag: 0x63, chromosome: "chr1", position: 100,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 100)],
            sequence: String(repeating: "A", count: 100),
            qualities: Array(repeating: 30, count: 100),
            mateChromosome: "chr1", matePosition: 300, insertSize: 400
        )
        let (normalFill, _) = ReadTrackRenderer.readColors(for: normal, colorMode: .insertSize, alpha: 1.0)

        // Too large insert size
        let tooLarge = AlignedRead(
            name: "r2", flag: 0x63, chromosome: "chr1", position: 100,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 100)],
            sequence: String(repeating: "A", count: 100),
            qualities: Array(repeating: 30, count: 100),
            mateChromosome: "chr1", matePosition: 5000, insertSize: 5000
        )
        let (largeFill, _) = ReadTrackRenderer.readColors(for: tooLarge, colorMode: .insertSize, alpha: 1.0)

        XCTAssertNotEqual(normalFill, largeFill, "Normal and too-large should have different colors")
    }

    func testReadColorsInsertSizeNotApplicable() {
        // Unpaired read in insertSize mode should fall back to strand colors
        let unpaired = makeRead(flag: 0) // not paired
        let (fill, _) = ReadTrackRenderer.readColors(for: unpaired, colorMode: .insertSize, alpha: 1.0)
        let (strandFill, _) = ReadTrackRenderer.readColors(for: unpaired, colorMode: .strand, alpha: 1.0)

        // Should match strand coloring since insertSize is notApplicable
        XCTAssertEqual(fill, strandFill, "NotApplicable insertSize should fall back to strand colors")
    }

    func testReadColorsMappingQualityMode() {
        let highQ = makeRead(mapq: 60)
        let lowQ = makeRead(mapq: 5)
        let unavailable = makeRead(mapq: 255)

        let (highFill, _) = ReadTrackRenderer.readColors(for: highQ, colorMode: .mappingQuality, alpha: 1.0)
        let (lowFill, _) = ReadTrackRenderer.readColors(for: lowQ, colorMode: .mappingQuality, alpha: 1.0)
        let (unavailFill, _) = ReadTrackRenderer.readColors(for: unavailable, colorMode: .mappingQuality, alpha: 1.0)

        XCTAssertNotEqual(highFill, lowFill, "High and low MAPQ should have different colors")
        XCTAssertNotEqual(highFill, unavailFill, "MAPQ=255 should be distinct from high quality")
        XCTAssertNotEqual(lowFill, unavailFill, "MAPQ=255 should be distinct from low quality")
    }

    func testReadColorsReadGroupMode() {
        let read = AlignedRead(
            name: "r1", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 100)],
            sequence: String(repeating: "A", count: 100),
            qualities: Array(repeating: 30, count: 100),
            readGroup: "RG1"
        )

        let colorMap = ["RG1": NSColor.red.cgColor, "RG2": NSColor.blue.cgColor]
        let (fill, _) = ReadTrackRenderer.readColors(for: read, colorMode: .readGroup, alpha: 1.0, readGroupColorMap: colorMap)

        // Should use the mapped color, not default strand colors
        let (strandFill, _) = ReadTrackRenderer.readColors(for: read, colorMode: .strand, alpha: 1.0)
        XCTAssertNotEqual(fill, strandFill, "Read group color should differ from strand color")
    }

    func testReadColorsReadGroupFallback() {
        // Read with no read group should fall back to strand colors
        let read = makeRead(flag: 99)
        let (fill, _) = ReadTrackRenderer.readColors(for: read, colorMode: .readGroup, alpha: 1.0, readGroupColorMap: [:])
        let (strandFill, _) = ReadTrackRenderer.readColors(for: read, colorMode: .strand, alpha: 1.0)
        XCTAssertEqual(fill, strandFill, "Missing read group should fall back to strand colors")
    }

    func testReadColorsFirstOfPairMode() {
        let first = makeRead(flag: 0x43) // paired + first in pair
        let second = makeRead(flag: 0x83) // paired + second in pair

        let (firstFill, _) = ReadTrackRenderer.readColors(for: first, colorMode: .firstOfPair, alpha: 1.0)
        let (secondFill, _) = ReadTrackRenderer.readColors(for: second, colorMode: .firstOfPair, alpha: 1.0)

        XCTAssertNotEqual(firstFill, secondFill, "First and second in pair should have different colors")
    }

    func testReadColorsFirstOfPairUnpaired() {
        // Unpaired read in firstOfPair mode should fall back to strand colors
        let unpaired = makeRead(flag: 0)
        let (fill, _) = ReadTrackRenderer.readColors(for: unpaired, colorMode: .firstOfPair, alpha: 1.0)
        let (strandFill, _) = ReadTrackRenderer.readColors(for: unpaired, colorMode: .strand, alpha: 1.0)
        XCTAssertEqual(fill, strandFill, "Unpaired read should fall back to strand colors")
    }

    func testReadColorsBaseQualityMode() {
        let highQ = AlignedRead(
            name: "r1", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 10)],
            sequence: String(repeating: "A", count: 10),
            qualities: Array(repeating: UInt8(40), count: 10)
        )
        let lowQ = AlignedRead(
            name: "r2", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 10)],
            sequence: String(repeating: "A", count: 10),
            qualities: Array(repeating: UInt8(5), count: 10)
        )

        let (highFill, _) = ReadTrackRenderer.readColors(for: highQ, colorMode: .baseQuality, alpha: 1.0)
        let (lowFill, _) = ReadTrackRenderer.readColors(for: lowQ, colorMode: .baseQuality, alpha: 1.0)

        XCTAssertNotEqual(highFill, lowFill, "High and low base quality should have different colors")
    }

    func testReadColorsBaseQualityEmptyQualities() {
        let noQ = AlignedRead(
            name: "r1", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 10)],
            sequence: String(repeating: "A", count: 10),
            qualities: []
        )

        // Should not crash with empty qualities
        let (fill, stroke) = ReadTrackRenderer.readColors(for: noQ, colorMode: .baseQuality, alpha: 1.0)
        XCTAssertNotNil(fill)
        XCTAssertNotNil(stroke)
    }

    func testReadColorsAlphaApplied() {
        let read = makeRead(flag: 99)
        let (fill1, _) = ReadTrackRenderer.readColors(for: read, colorMode: .strand, alpha: 1.0)
        let (fill05, _) = ReadTrackRenderer.readColors(for: read, colorMode: .strand, alpha: 0.5)

        // Alpha=0.5 fill should differ from alpha=1.0 fill
        XCTAssertNotEqual(fill1, fill05, "Different alpha values should produce different colors")
    }

    // MARK: - Build Read Group Color Map

    func testBuildReadGroupColorMap() {
        let reads = [
            AlignedRead(
                name: "r1", flag: 0, chromosome: "chr1", position: 100,
                mapq: 60, cigar: [CIGAROperation(op: .match, length: 50)],
                sequence: String(repeating: "A", count: 50), qualities: [],
                readGroup: "RG1"
            ),
            AlignedRead(
                name: "r2", flag: 0, chromosome: "chr1", position: 200,
                mapq: 60, cigar: [CIGAROperation(op: .match, length: 50)],
                sequence: String(repeating: "A", count: 50), qualities: [],
                readGroup: "RG2"
            ),
            AlignedRead(
                name: "r3", flag: 0, chromosome: "chr1", position: 300,
                mapq: 60, cigar: [CIGAROperation(op: .match, length: 50)],
                sequence: String(repeating: "A", count: 50), qualities: [],
                readGroup: "RG1" // duplicate
            ),
        ]

        let map = ReadTrackRenderer.buildReadGroupColorMap(from: reads)
        XCTAssertEqual(map.count, 2, "Should have 2 unique read groups")
        XCTAssertNotNil(map["RG1"])
        XCTAssertNotNil(map["RG2"])
        XCTAssertNotEqual(map["RG1"], map["RG2"], "Different read groups should get different colors")
    }

    func testBuildReadGroupColorMapEmpty() {
        let map = ReadTrackRenderer.buildReadGroupColorMap(from: [])
        XCTAssertTrue(map.isEmpty)
    }

    func testBuildReadGroupColorMapNoGroups() {
        let reads = [makeRead(name: "r1"), makeRead(name: "r2")]
        let map = ReadTrackRenderer.buildReadGroupColorMap(from: reads)
        XCTAssertTrue(map.isEmpty, "Reads without read groups should produce empty map")
    }

    // MARK: - Pack Reads Sort Modes

    func testPackReadsSortByReadName() {
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 1000)
        let readC = makeRead(name: "charlie", position: 100, cigarLength: 50)
        let readA = makeRead(name: "alpha", position: 300, cigarLength: 50)
        let readB = makeRead(name: "bravo", position: 200, cigarLength: 50)

        let (packed, _) = ReadTrackRenderer.packReads([readC, readA, readB], frame: frame, sortMode: .readName)
        XCTAssertEqual(packed[0].read.name, "alpha")
        XCTAssertEqual(packed[1].read.name, "bravo")
        XCTAssertEqual(packed[2].read.name, "charlie")
    }

    func testPackReadsSortByStrand() {
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 1000)
        let reverse = makeRead(name: "rev", flag: 0x10, position: 100, cigarLength: 50) // reverse strand
        let forward = makeRead(name: "fwd", flag: 0, position: 300, cigarLength: 50) // forward strand

        let (packed, _) = ReadTrackRenderer.packReads([reverse, forward], frame: frame, sortMode: .strand)
        // Forward first, then reverse
        XCTAssertFalse(packed[0].read.isReverse, "Forward reads should come first in strand sort")
        XCTAssertTrue(packed[1].read.isReverse, "Reverse reads should come after forward reads")
    }

    func testPackReadsSortByMappingQuality() {
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 1000)
        let lowQ = makeRead(name: "lowq", position: 100, mapq: 10, cigarLength: 50)
        let highQ = makeRead(name: "highq", position: 300, mapq: 60, cigarLength: 50)
        let midQ = makeRead(name: "midq", position: 500, mapq: 30, cigarLength: 50)

        let (packed, _) = ReadTrackRenderer.packReads([lowQ, highQ, midQ], frame: frame, sortMode: .mappingQuality)
        // Highest MAPQ first
        XCTAssertEqual(packed[0].read.mapq, 60)
        XCTAssertEqual(packed[1].read.mapq, 30)
        XCTAssertEqual(packed[2].read.mapq, 10)
    }

    func testPackReadsSortByInsertSize() {
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 1000)
        let large = AlignedRead(
            name: "large", flag: 0x63, chromosome: "chr1", position: 100,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 50)],
            sequence: String(repeating: "A", count: 50),
            qualities: Array(repeating: 30, count: 50),
            insertSize: 5000
        )
        let small = AlignedRead(
            name: "small", flag: 0x63, chromosome: "chr1", position: 300,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 50)],
            sequence: String(repeating: "A", count: 50),
            qualities: Array(repeating: 30, count: 50),
            insertSize: 200
        )
        let negative = AlignedRead(
            name: "neg", flag: 0x63, chromosome: "chr1", position: 500,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 50)],
            sequence: String(repeating: "A", count: 50),
            qualities: Array(repeating: 30, count: 50),
            insertSize: -300
        )

        let (packed, _) = ReadTrackRenderer.packReads([large, small, negative], frame: frame, sortMode: .insertSize)
        // Sort by abs(insertSize), smallest first
        XCTAssertEqual(packed[0].read.name, "small")  // |200|
        XCTAssertEqual(packed[1].read.name, "neg")     // |-300| = 300
        XCTAssertEqual(packed[2].read.name, "large")   // |5000|
    }

    func testPackReadsSortByBaseAtPosition() {
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 1000)
        // Create reads with different bases at position 105
        let readWithT = AlignedRead(
            name: "withT", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 50)],
            sequence: "AAAAATAAAA" + String(repeating: "A", count: 40), // T at offset 5 → refPos 105
            qualities: Array(repeating: 30, count: 50)
        )
        let readWithA = AlignedRead(
            name: "withA", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 50)],
            sequence: String(repeating: "A", count: 50), // A at position 105
            qualities: Array(repeating: 30, count: 50)
        )

        let (packed, _) = ReadTrackRenderer.packReads(
            [readWithT, readWithA], frame: frame,
            sortMode: .baseAtPosition, sortPosition: 105
        )
        XCTAssertEqual(packed.count, 2)
        // A (65) < T (84) in ASCII
        XCTAssertEqual(packed[0].read.name, "withA")
        XCTAssertEqual(packed[1].read.name, "withT")
    }

    func testPackReadsSortByBaseAtPositionNoPosition() {
        // Without sortPosition, baseAtPosition falls back to position sort
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 1000)
        let read1 = makeRead(name: "r_later", position: 500, cigarLength: 50)
        let read2 = makeRead(name: "r_earlier", position: 100, cigarLength: 50)

        let (packed, _) = ReadTrackRenderer.packReads([read1, read2], frame: frame, sortMode: .baseAtPosition)
        XCTAssertEqual(packed[0].read.name, "r_earlier", "Should fall back to position sort")
        XCTAssertEqual(packed[1].read.name, "r_later")
    }

    // MARK: - Coverage with Introns (N operations)

    func testDrawCoverageWithIntronsDoesNotCrash() {
        let frame = makeFrame(start: 0, end: 10000, pixelWidth: 200)
        // RNA-seq read: 50M10000N50M (50 match, 10kb intron, 50 match)
        let cigar = [
            CIGAROperation(op: .match, length: 50),
            CIGAROperation(op: .skip, length: 10000),
            CIGAROperation(op: .match, length: 50),
        ]
        let reads = [
            AlignedRead(
                name: "rna_read", flag: 0, chromosome: "chr1", position: 100,
                mapq: 60, cigar: cigar,
                sequence: String(repeating: "A", count: 100),
                qualities: Array(repeating: 30, count: 100)
            )
        ]

        let width = 200, height = 60
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        ReadTrackRenderer.drawCoverage(reads: reads, frame: frame, context: context, rect: rect)
        // The intron region should not contribute to coverage (N operations are skipped)
    }

    // MARK: - Split Read Indicator Smoke Test

    func testDrawSplitReadIndicatorsDoesNotCrash() {
        let frame = makeFrame(start: 0, end: 10000, pixelWidth: 1000)
        let read = AlignedRead(
            name: "split", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 100)],
            sequence: String(repeating: "A", count: 100),
            qualities: Array(repeating: 30, count: 100),
            supplementaryAlignments: "chr1,5000,+,50M50S,40,2;"
        )

        let width = 1000, height = 100
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        ReadTrackRenderer.drawSplitReadIndicators(
            read: read, frame: frame, context: context,
            y: 10, readHeight: 14, currentChromosome: "chr1"
        )
    }

    func testDrawSplitReadIndicatorsSkipsDifferentChromosome() {
        let frame = makeFrame(start: 0, end: 10000, pixelWidth: 1000)
        let read = AlignedRead(
            name: "split", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 100)],
            sequence: String(repeating: "A", count: 100),
            qualities: Array(repeating: 30, count: 100),
            supplementaryAlignments: "chr2,5000,+,50M50S,40,2;" // different chrom
        )

        let width = 1000, height = 100
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Should not crash; supplementary on chr2 should be skipped for chr1 view
        ReadTrackRenderer.drawSplitReadIndicators(
            read: read, frame: frame, context: context,
            y: 10, readHeight: 14, currentChromosome: "chr1"
        )
    }

    // MARK: - Mate Pair Links Smoke Test

    func testDrawMatePairLinksDoesNotCrash() {
        let frame = makeFrame(start: 0, end: 1000, pixelWidth: 500)
        let read1 = AlignedRead(
            name: "mate", flag: 0x63, chromosome: "chr1", position: 100,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 100)],
            sequence: String(repeating: "A", count: 100),
            qualities: Array(repeating: 30, count: 100),
            mateChromosome: "chr1", matePosition: 400
        )
        let read2 = AlignedRead(
            name: "mate", flag: 0xA3, chromosome: "chr1", position: 400,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 100)],
            sequence: String(repeating: "A", count: 100),
            qualities: Array(repeating: 30, count: 100),
            mateChromosome: "chr1", matePosition: 100
        )

        let packed: [(row: Int, read: AlignedRead)] = [(0, read1), (0, read2)]
        let width = 500, height = 100
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        ReadTrackRenderer.drawMatePairLinks(
            packedReads: packed, frame: frame, context: context,
            rect: rect, readHeight: 6
        )
    }

    // MARK: - Base Quality Overlay Smoke Test

    func testDrawBaseQualityOverlayDoesNotCrash() {
        let frame = makeFrame(start: 0, end: 200, pixelWidth: 1000)
        var qualities = Array(repeating: UInt8(30), count: 50)
        qualities[10] = 5  // low quality base
        qualities[20] = 10 // low quality base

        let read = AlignedRead(
            name: "bq_read", flag: 0, chromosome: "chr1", position: 50,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 50)],
            sequence: String(repeating: "A", count: 50),
            qualities: qualities
        )

        let width = 1000, height = 100
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        ReadTrackRenderer.drawBaseQualityOverlay(
            read: read, frame: frame, context: context,
            y: 10, readHeight: 14
        )
    }

    func testDrawBaseQualityOverlayEmptyQualities() {
        let frame = makeFrame(start: 0, end: 200, pixelWidth: 1000)
        let read = AlignedRead(
            name: "noq", flag: 0, chromosome: "chr1", position: 50,
            mapq: 60, cigar: [CIGAROperation(op: .match, length: 50)],
            sequence: String(repeating: "A", count: 50),
            qualities: []
        )

        let width = 1000, height = 100
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Should return early without crash
        ReadTrackRenderer.drawBaseQualityOverlay(
            read: read, frame: frame, context: context,
            y: 10, readHeight: 14
        )
    }
}
