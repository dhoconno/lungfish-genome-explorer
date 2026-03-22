// ReferenceFrameTests.swift - Safety-net tests for ReferenceFrame
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishUI
import LungfishCore

@MainActor
final class ReferenceFrameTests: XCTestCase {

    // MARK: - Constants

    /// A representative chromosome length used throughout tests (chr1 length in hg38).
    private let chr1Length = 248_956_422

    // MARK: - Initialization / Default State

    func testInitialStateShowsEntireChromosome() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: chr1Length, widthInPixels: 1000)

        XCTAssertEqual(frame.chromosome, "chr1")
        XCTAssertEqual(frame.chromosomeLength, chr1Length)
        XCTAssertEqual(frame.origin, 0, "Origin should start at 0")
        XCTAssertEqual(frame.widthInPixels, 1000)
        XCTAssertEqual(frame.scale, Double(chr1Length) / 1000.0, accuracy: 0.001)
    }

    func testInitialEndEqualsChromosomeLength() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: chr1Length, widthInPixels: 1000)

        XCTAssertEqual(frame.end, Double(chr1Length), accuracy: 1.0,
                        "End should equal chromosome length when showing entire chromosome")
    }

    func testInitWithExplicitStartEnd() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 1_000_000, end: 2_000_000,
            chromosomeLength: chr1Length, widthInPixels: 500
        )

        XCTAssertEqual(frame.origin, 1_000_000)
        XCTAssertEqual(frame.end, 2_000_000, accuracy: 0.001)
        XCTAssertEqual(frame.scale, 1_000_000.0 / 500.0, accuracy: 0.001)
    }

    func testInitClampsWidthToMinimumOne() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: 10_000, widthInPixels: 0)

        XCTAssertEqual(frame.widthInPixels, 1,
                        "Width of 0 should be clamped to 1 to avoid division by zero")
    }

    // MARK: - Jump To Region

    func testJumpToRegionSetsOriginAndScale() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: chr1Length, widthInPixels: 1000)

        frame.jumpTo(start: 5_000_000, end: 6_000_000)

        XCTAssertEqual(frame.origin, 5_000_000, accuracy: 0.001)
        XCTAssertEqual(frame.end, 6_000_000, accuracy: 0.001)
        XCTAssertEqual(frame.scale, 1_000_000.0 / 1000.0, accuracy: 0.001)
    }

    func testJumpToGenomicRegionStruct() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: chr1Length, widthInPixels: 1000)
        let region = GenomicRegion(chromosome: "chr1", start: 10_000_000, end: 11_000_000)

        frame.jumpTo(region: region)

        XCTAssertEqual(frame.origin, 10_000_000, accuracy: 0.001)
        XCTAssertEqual(frame.end, 11_000_000, accuracy: 0.001)
    }

    func testJumpToClampsStartToZero() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: chr1Length, widthInPixels: 1000)

        frame.jumpTo(start: -500, end: 10_000)

        XCTAssertEqual(frame.origin, 0, "Negative start should be clamped to 0")
        XCTAssertEqual(frame.end, 10_000, accuracy: 0.001)
    }

    func testJumpToClampsEndToChromosomeLength() {
        let length = 100_000
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: length, widthInPixels: 1000)

        frame.jumpTo(start: 50_000, end: 200_000)

        XCTAssertEqual(frame.end, Double(length), accuracy: 0.001,
                        "End should be clamped to chromosome length")
    }

    // MARK: - Screen Position <-> Genomic Position Conversion

    func testScreenToGenomicConversion() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 1000, end: 2000,
            chromosomeLength: 10_000, widthInPixels: 1000
        )

        // At pixel 0 -> genomic 1000; at pixel 500 -> genomic 1500; at pixel 1000 -> genomic 2000
        XCTAssertEqual(frame.genomicPosition(for: 0), 1000, accuracy: 0.001)
        XCTAssertEqual(frame.genomicPosition(for: 500), 1500, accuracy: 0.001)
        XCTAssertEqual(frame.genomicPosition(for: 1000), 2000, accuracy: 0.001)
    }

    func testGenomicToScreenConversion() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 1000, end: 2000,
            chromosomeLength: 10_000, widthInPixels: 1000
        )

        XCTAssertEqual(frame.screenPosition(for: 1000), 0, accuracy: 0.001)
        XCTAssertEqual(frame.screenPosition(for: 1500), 500, accuracy: 0.001)
        XCTAssertEqual(frame.screenPosition(for: 2000), 1000, accuracy: 0.001)
    }

    func testRoundTripConversion() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 50_000, end: 100_000,
            chromosomeLength: chr1Length, widthInPixels: 800
        )

        let originalGenomic = 75_000.0
        let screen = frame.screenPosition(for: originalGenomic)
        let backToGenomic = frame.genomicPosition(for: screen)

        XCTAssertEqual(backToGenomic, originalGenomic, accuracy: 0.01,
                        "Round-trip conversion should preserve the genomic position")
    }

    func testScreenRectConversion() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 0, end: 1000,
            chromosomeLength: 1000, widthInPixels: 1000
        )
        // 1 bp per pixel, so genomic [100, 200) -> screen rect x=100, width=100
        let rect = frame.screenRect(for: 100, end: 200, y: 10, height: 20)

        XCTAssertEqual(rect.origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 10, accuracy: 0.001)
        XCTAssertEqual(rect.size.width, 100, accuracy: 0.001)
        XCTAssertEqual(rect.size.height, 20, accuracy: 0.001)
    }

    // MARK: - Zoom

    func testZoomInReducesWindowLength() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: chr1Length, widthInPixels: 1000)
        let windowBefore = frame.windowLength

        frame.zoomIn(factor: 2.0)

        XCTAssertLessThan(frame.windowLength, windowBefore,
                           "Zooming in should reduce the visible window length")
        XCTAssertEqual(frame.windowLength, windowBefore / 2.0, accuracy: 1.0)
    }

    func testZoomOutIncreasesWindowLength() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: chr1Length, widthInPixels: 1000)
        frame.jumpTo(start: 10_000_000, end: 20_000_000)
        let windowBefore = frame.windowLength

        frame.zoomOut(factor: 2.0)

        XCTAssertGreaterThan(frame.windowLength, windowBefore,
                              "Zooming out should increase the visible window length")
        XCTAssertEqual(frame.windowLength, windowBefore * 2.0, accuracy: 1.0)
    }

    func testZoomInCannotGoBelowMinBP() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 5000, end: 5040,
            chromosomeLength: 100_000, widthInPixels: 1000
        )
        // Already at minBP (40 bp visible), zooming in further should not reduce below minBP
        frame.zoomIn(factor: 10.0)

        XCTAssertGreaterThanOrEqual(frame.windowLength, Double(ReferenceFrame.minBP),
                                     "Window length should never go below minBP (\(ReferenceFrame.minBP))")
    }

    func testZoomOutCannotExceedChromosomeLength() {
        let length = 100_000
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: length, widthInPixels: 1000)

        // Already showing full chromosome, zooming out further should not exceed chromosome length
        frame.zoomOut(factor: 10.0)

        XCTAssertLessThanOrEqual(frame.windowLength, Double(length) + 1.0,
                                  "Window length should not exceed chromosome length")
    }

    func testZoomCenteredAtScreenPosition() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 0, end: 10_000,
            chromosomeLength: 100_000, widthInPixels: 1000
        )

        // Zoom 2x centered at left edge (screenX = 0): the left edge stays at genomic 0
        frame.zoom(by: 2.0, centeredAt: 0)

        XCTAssertEqual(frame.origin, 0, accuracy: 0.1,
                        "Zooming centered at left edge should keep origin at 0")
        XCTAssertEqual(frame.windowLength, 5000, accuracy: 1.0,
                        "Window length should halve when zooming 2x in")
    }

    func testZoomToFitResetsToFullChromosome() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: chr1Length, widthInPixels: 1000)
        frame.jumpTo(start: 5_000_000, end: 6_000_000)

        frame.zoomToFit()

        XCTAssertEqual(frame.origin, 0)
        XCTAssertEqual(frame.end, Double(chr1Length), accuracy: 1.0)
    }

    func testZoomLevelZeroWhenShowingFullChromosome() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: chr1Length, widthInPixels: 1000)

        XCTAssertEqual(frame.zoom, 0, "Zoom level should be 0 when entire chromosome is visible")
    }

    func testZoomLevelIncreasesWhenZoomedIn() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: chr1Length, widthInPixels: 1000)
        let zoomBefore = frame.zoom

        frame.jumpTo(start: 0, end: 1000)

        XCTAssertGreaterThan(frame.zoom, zoomBefore,
                              "Zoom level should increase when viewing a smaller region")
    }

    // MARK: - Pan

    func testPanRightIncreasesOrigin() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: chr1Length, widthInPixels: 1000)
        frame.jumpTo(start: 5_000_000, end: 6_000_000)
        let originBefore = frame.origin

        frame.pan(by: 100) // pan right by 100 pixels

        XCTAssertGreaterThan(frame.origin, originBefore, "Panning right should increase origin")
    }

    func testPanLeftDecreasesOrigin() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: chr1Length, widthInPixels: 1000)
        frame.jumpTo(start: 5_000_000, end: 6_000_000)
        let originBefore = frame.origin

        frame.pan(by: -100) // pan left by 100 pixels

        XCTAssertLessThan(frame.origin, originBefore, "Panning left should decrease origin")
    }

    func testPanClampedAtLeftBoundary() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 100, end: 10_100,
            chromosomeLength: 100_000, widthInPixels: 1000
        )

        // Pan far to the left -- should clamp at origin 0
        frame.pan(by: -100_000)

        XCTAssertEqual(frame.origin, 0, accuracy: 0.001,
                        "Origin should not go below 0 when panning left")
    }

    func testPanClampedAtRightBoundary() {
        let length = 100_000
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 90_000, end: 95_000,
            chromosomeLength: length, widthInPixels: 1000
        )

        // Pan far to the right
        frame.pan(by: 100_000)

        XCTAssertLessThanOrEqual(frame.end, Double(length) + 1.0,
                                  "End should not exceed chromosome length when panning right")
        XCTAssertGreaterThanOrEqual(frame.origin, 0, "Origin should remain non-negative")
    }

    func testPanPreservesWindowLength() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: chr1Length, widthInPixels: 1000)
        frame.jumpTo(start: 50_000_000, end: 60_000_000)
        let windowBefore = frame.windowLength

        frame.pan(by: 200)

        XCTAssertEqual(frame.windowLength, windowBefore, accuracy: 0.001,
                        "Panning should not change the window length (scale is preserved)")
    }

    // MARK: - Bases Per Pixel (Scale)

    func testBasesPerPixelCalculation() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 0, end: 10_000,
            chromosomeLength: 100_000, widthInPixels: 1000
        )

        // 10,000 bp / 1000 px = 10 bp/px
        XCTAssertEqual(frame.scale, 10.0, accuracy: 0.001)
    }

    func testWindowLengthMatchesScaleTimesWidth() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 1000, end: 5000,
            chromosomeLength: 100_000, widthInPixels: 800
        )

        XCTAssertEqual(frame.windowLength, Double(frame.widthInPixels) * frame.scale, accuracy: 0.001)
    }

    // MARK: - Width Update (Resize)

    func testUpdateWidthPreservesVisibleRange() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 10_000, end: 20_000,
            chromosomeLength: 100_000, widthInPixels: 1000
        )
        let windowBefore = frame.windowLength
        let originBefore = frame.origin

        frame.updateWidth(2000)

        XCTAssertEqual(frame.widthInPixels, 2000)
        XCTAssertEqual(frame.origin, originBefore, accuracy: 0.001,
                        "Origin should be preserved on resize")
        XCTAssertEqual(frame.windowLength, windowBefore, accuracy: 1.0,
                        "Genomic window length should be preserved on resize")
    }

    func testUpdateWidthAdjustsScale() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 0, end: 10_000,
            chromosomeLength: 100_000, widthInPixels: 1000
        )

        frame.updateWidth(500)

        // Same 10,000 bp window now in 500 px -> scale = 20 bp/px
        XCTAssertEqual(frame.scale, 20.0, accuracy: 0.001)
    }

    func testUpdateWidthIgnoresZeroOrNegative() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: 10_000, widthInPixels: 1000)
        let scaleBefore = frame.scale

        frame.updateWidth(0)
        XCTAssertEqual(frame.scale, scaleBefore, accuracy: 0.001,
                        "Width of 0 should be ignored")

        frame.updateWidth(-5)
        XCTAssertEqual(frame.scale, scaleBefore, accuracy: 0.001,
                        "Negative width should be ignored")
    }

    // MARK: - Tile Index

    func testVisibleTileIndicesIncludeViewBounds() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 0, end: 10_000,
            chromosomeLength: 100_000, widthInPixels: 1000
        )

        let tiles = frame.visibleTileIndices()

        XCTAssertFalse(tiles.isEmpty, "There should be at least one visible tile")
        XCTAssertTrue(tiles.contains(0), "Tile 0 should be visible when origin is 0")
    }

    func testRangeForTileIsWithinChromosomeBounds() {
        let length = 100_000
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 0, end: 10_000,
            chromosomeLength: length, widthInPixels: 1000
        )

        let tiles = frame.visibleTileIndices()
        for tileIndex in tiles {
            let range = frame.rangeForTile(tileIndex)
            XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
            XCTAssertLessThanOrEqual(range.upperBound, length)
        }
    }

    // MARK: - Visibility Checks

    func testIsVisibleForOverlappingRange() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 1000, end: 2000,
            chromosomeLength: 10_000, widthInPixels: 1000
        )

        XCTAssertTrue(frame.isVisible(start: 1500, end: 1800),
                       "Range fully inside view should be visible")
        XCTAssertTrue(frame.isVisible(start: 500, end: 1500),
                       "Range overlapping left edge should be visible")
        XCTAssertTrue(frame.isVisible(start: 1800, end: 2500),
                       "Range overlapping right edge should be visible")
        XCTAssertTrue(frame.isVisible(start: 500, end: 2500),
                       "Range spanning entire view should be visible")
    }

    func testIsVisibleForNonOverlappingRange() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 1000, end: 2000,
            chromosomeLength: 10_000, widthInPixels: 1000
        )

        XCTAssertFalse(frame.isVisible(start: 0, end: 1000),
                        "Range ending exactly at origin should not be visible (half-open)")
        XCTAssertFalse(frame.isVisible(start: 2000, end: 3000),
                        "Range starting exactly at end should not be visible (half-open)")
        XCTAssertFalse(frame.isVisible(start: 5000, end: 6000),
                        "Range far to the right should not be visible")
    }

    func testIsVisibleForGenomicRegionChecksChromosome() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 0, end: 10_000,
            chromosomeLength: 100_000, widthInPixels: 1000
        )
        let sameChrom = GenomicRegion(chromosome: "chr1", start: 500, end: 1500)
        let differentChrom = GenomicRegion(chromosome: "chr2", start: 500, end: 1500)

        XCTAssertTrue(frame.isVisible(region: sameChrom))
        XCTAssertFalse(frame.isVisible(region: differentChrom),
                        "Region on a different chromosome should not be visible")
    }

    // MARK: - Set Chromosome

    func testSetChromosomeResetsView() {
        let frame = ReferenceFrame(chromosome: "chr1", chromosomeLength: chr1Length, widthInPixels: 1000)
        frame.jumpTo(start: 50_000_000, end: 60_000_000)

        let newLength = 100_000_000
        frame.setChromosome("chr2", length: newLength)

        XCTAssertEqual(frame.chromosome, "chr2")
        XCTAssertEqual(frame.chromosomeLength, newLength)
        XCTAssertEqual(frame.origin, 0, "Origin should reset to 0")
        XCTAssertEqual(frame.end, Double(newLength), accuracy: 1.0,
                        "View should show entire new chromosome")
    }

    // MARK: - Equatable

    func testEquatable() {
        let frame1 = ReferenceFrame(
            chromosome: "chr1", start: 1000, end: 2000,
            chromosomeLength: 10_000, widthInPixels: 1000
        )
        let frame2 = ReferenceFrame(
            chromosome: "chr1", start: 1000, end: 2000,
            chromosomeLength: 10_000, widthInPixels: 1000
        )
        let frame3 = ReferenceFrame(
            chromosome: "chr2", start: 1000, end: 2000,
            chromosomeLength: 10_000, widthInPixels: 1000
        )

        XCTAssertEqual(frame1, frame2, "Frames with identical state should be equal")
        XCTAssertNotEqual(frame1, frame3, "Frames on different chromosomes should not be equal")
    }

    // MARK: - CenterOn

    func testCenterOnPosition() {
        let frame = ReferenceFrame(
            chromosome: "chr1", start: 0, end: 10_000,
            chromosomeLength: 100_000, widthInPixels: 1000
        )

        frame.centerOn(position: 50_000)

        let midpoint = frame.origin + frame.windowLength / 2.0
        XCTAssertEqual(midpoint, 50_000, accuracy: 1.0,
                        "The view center should be at the requested position")
    }
}
