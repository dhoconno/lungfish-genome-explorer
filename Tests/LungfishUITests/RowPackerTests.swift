// RowPackerTests.swift - Safety-net tests for RowPacker
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishUI
import LungfishCore

// MARK: - Test Helper

/// Minimal Packable type for testing without depending on SequenceAnnotation details.
private struct TestFeature: Packable {
    let start: Int
    let end: Int

    init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

@MainActor
final class RowPackerTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a ReferenceFrame that shows the given range at 1 bp/px.
    private func makeFrame(start: Int, end: Int) -> ReferenceFrame {
        let width = end - start
        return ReferenceFrame(
            chromosome: "chr1",
            start: Double(start),
            end: Double(end),
            chromosomeLength: max(end, 100_000),
            widthInPixels: width
        )
    }

    // MARK: - Empty Input

    func testPackEmptyInputReturnsEmpty() {
        let packer = RowPacker<TestFeature>()
        let frame = makeFrame(start: 0, end: 10_000)

        let result = packer.pack([], in: frame)

        XCTAssertTrue(result.isEmpty, "Packing no features should produce an empty result")
    }

    // MARK: - Single Feature

    func testPackSingleFeatureAssignsRowZero() {
        let packer = RowPacker<TestFeature>()
        let frame = makeFrame(start: 0, end: 10_000)
        let features = [TestFeature(start: 100, end: 500)]

        let result = packer.pack(features, in: frame)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].row, 0, "A single feature should be placed in row 0")
    }

    func testPackSingleFeatureScreenCoordinates() {
        let packer = RowPacker<TestFeature>(minGap: 0)
        // 1 bp per pixel
        let frame = makeFrame(start: 0, end: 1000)
        let features = [TestFeature(start: 100, end: 300)]

        let result = packer.pack(features, in: frame)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].screenStart, 100, accuracy: 0.5)
        XCTAssertEqual(result[0].screenEnd, 300, accuracy: 0.5)
    }

    // MARK: - Non-Overlapping Features

    func testNonOverlappingFeaturesShareSameRow() {
        let packer = RowPacker<TestFeature>(minGap: 5)
        let frame = makeFrame(start: 0, end: 10_000)
        // Two features far apart -- no overlap
        let features = [
            TestFeature(start: 100, end: 200),
            TestFeature(start: 5000, end: 5100),
        ]

        let result = packer.pack(features, in: frame)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].row, 0)
        XCTAssertEqual(result[1].row, 0,
                        "Non-overlapping features should be packed into the same row")
    }

    // MARK: - Overlapping Features

    func testOverlappingFeaturesUseDifferentRows() {
        let packer = RowPacker<TestFeature>(minGap: 0)
        let frame = makeFrame(start: 0, end: 10_000)
        let features = [
            TestFeature(start: 100, end: 500),
            TestFeature(start: 300, end: 700),
        ]

        let result = packer.pack(features, in: frame)

        XCTAssertEqual(result.count, 2)
        XCTAssertNotEqual(result[0].row, result[1].row,
                           "Overlapping features should be placed in different rows")
    }

    func testThreeOverlappingFeaturesUseThreeRows() {
        let packer = RowPacker<TestFeature>(minGap: 0)
        let frame = makeFrame(start: 0, end: 10_000)
        // All three overlap each other
        let features = [
            TestFeature(start: 100, end: 500),
            TestFeature(start: 200, end: 600),
            TestFeature(start: 300, end: 700),
        ]

        let result = packer.pack(features, in: frame)

        XCTAssertEqual(result.count, 3)
        let rows = Set(result.map(\.row))
        XCTAssertEqual(rows.count, 3, "Three mutually overlapping features need three distinct rows")
    }

    // MARK: - Min Gap

    func testMinGapPreventsPackingTooClose() {
        let packer = RowPacker<TestFeature>(minGap: 50)
        // 1 bp/px
        let frame = makeFrame(start: 0, end: 10_000)
        // Feature A ends at 500 (screen px 500), feature B starts at 520 (screen px 520)
        // Gap is 20 px, which is less than minGap of 50 -> should be on different rows
        let features = [
            TestFeature(start: 0, end: 500),
            TestFeature(start: 520, end: 1000),
        ]

        let result = packer.pack(features, in: frame)

        XCTAssertEqual(result.count, 2)
        XCTAssertNotEqual(result[0].row, result[1].row,
                           "Features closer than minGap should not share a row")
    }

    func testMinGapAllowsPackingWhenSufficientDistance() {
        let packer = RowPacker<TestFeature>(minGap: 10)
        // 1 bp/px
        let frame = makeFrame(start: 0, end: 10_000)
        // Feature A ends at 500, feature B starts at 520 -> gap = 20 px > minGap = 10
        let features = [
            TestFeature(start: 0, end: 500),
            TestFeature(start: 520, end: 1000),
        ]

        let result = packer.pack(features, in: frame)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].row, result[1].row,
                        "Features separated by more than minGap should share a row")
    }

    // MARK: - Max Rows Limit

    func testMaxRowsLimitCapsRowCount() {
        let maxRows = 3
        let packer = RowPacker<TestFeature>(minGap: 0, maxRows: maxRows)
        let frame = makeFrame(start: 0, end: 10_000)
        // Five fully overlapping features -- without limit would need 5 rows
        let features = (0..<5).map { _ in TestFeature(start: 100, end: 500) }

        let result = packer.pack(features, in: frame)

        XCTAssertEqual(result.count, 5)
        let maxRowUsed = result.map(\.row).max() ?? 0
        XCTAssertLessThanOrEqual(maxRowUsed, maxRows - 1,
                                  "Row indices should not exceed maxRows - 1")
    }

    func testOverflowFeaturesPackedIntoLastRow() {
        let maxRows = 2
        let packer = RowPacker<TestFeature>(minGap: 0, maxRows: maxRows)
        let frame = makeFrame(start: 0, end: 10_000)
        // Three fully overlapping features; rows 0 and 1 take first two, third overflows to row 1
        let features = [
            TestFeature(start: 100, end: 500),
            TestFeature(start: 200, end: 600),
            TestFeature(start: 300, end: 700),
        ]

        let result = packer.pack(features, in: frame)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[2].row, maxRows - 1,
                        "Overflow features should be packed into the last row")
    }

    // MARK: - Features Outside View Filtered

    func testFeaturesOutsideViewAreFiltered() {
        let packer = RowPacker<TestFeature>()
        let frame = makeFrame(start: 1000, end: 2000)
        let features = [
            TestFeature(start: 0, end: 100),     // entirely before view
            TestFeature(start: 1500, end: 1800),  // inside view
            TestFeature(start: 5000, end: 6000),  // entirely after view
        ]

        let result = packer.pack(features, in: frame)

        XCTAssertEqual(result.count, 1, "Only the feature inside the visible range should be packed")
        XCTAssertEqual(result[0].feature.start, 1500)
    }

    // MARK: - Sorting

    func testFeaturesAreSortedByStartBeforePacking() {
        let packer = RowPacker<TestFeature>(minGap: 0)
        let frame = makeFrame(start: 0, end: 10_000)
        // Input deliberately unsorted
        let features = [
            TestFeature(start: 5000, end: 5500),
            TestFeature(start: 100, end: 300),
            TestFeature(start: 2000, end: 2500),
        ]

        let result = packer.pack(features, in: frame)

        XCTAssertEqual(result.count, 3)
        // All non-overlapping, so they should all fit in row 0
        XCTAssertTrue(result.allSatisfy { $0.row == 0 },
                       "Non-overlapping unsorted features should all pack into row 0")
        // Result should be in sorted order
        for i in 1..<result.count {
            XCTAssertGreaterThanOrEqual(result[i].feature.start, result[i - 1].feature.start,
                                         "Packed result should be in sorted start-position order")
        }
    }

    // MARK: - Stress Test

    func testPackManyFeaturesPerformance() {
        let packer = RowPacker<TestFeature>(minGap: 2)
        let frame = makeFrame(start: 0, end: 1_000_000)
        // 10,000 features, each 100 bp long, placed every 50 bp (lots of overlap)
        let features = (0..<10_000).map { i in
            TestFeature(start: i * 50, end: i * 50 + 100)
        }

        let result = packer.pack(features, in: frame)

        XCTAssertGreaterThan(result.count, 0, "Should pack all visible features")
        // With 100bp features every 50bp at 1bp/px, each feature overlaps its neighbor
        // so we expect at least 2 rows
        let rowCount = (result.map(\.row).max() ?? 0) + 1
        XCTAssertGreaterThanOrEqual(rowCount, 2, "Overlapping features should require multiple rows")
    }

    // MARK: - packWithRowCount

    func testPackWithRowCountReturnsCorrectCount() {
        let packer = RowPacker<TestFeature>(minGap: 0)
        let frame = makeFrame(start: 0, end: 10_000)
        let features = [
            TestFeature(start: 100, end: 500),
            TestFeature(start: 200, end: 600),
        ]

        let (packed, rowCount) = packer.packWithRowCount(features, in: frame)

        XCTAssertEqual(packed.count, 2)
        XCTAssertEqual(rowCount, 2, "Two overlapping features should yield rowCount = 2")
    }

    func testPackWithRowCountEmptyInputReturnsZeroRows() {
        let packer = RowPacker<TestFeature>()
        let frame = makeFrame(start: 0, end: 10_000)

        let (packed, rowCount) = packer.packWithRowCount([], in: frame)

        XCTAssertTrue(packed.isEmpty)
        XCTAssertEqual(rowCount, 0)
    }

    // MARK: - SequenceAnnotation Packable Conformance

    func testSequenceAnnotationPackableConformance() {
        let packer = RowPacker<SequenceAnnotation>(minGap: 5)
        let frame = makeFrame(start: 0, end: 50_000)

        let annotations = [
            SequenceAnnotation(type: .gene, name: "GeneA", chromosome: "chr1", start: 1000, end: 5000),
            SequenceAnnotation(type: .gene, name: "GeneB", chromosome: "chr1", start: 20_000, end: 25_000),
        ]

        let result = packer.pack(annotations, in: frame)

        XCTAssertEqual(result.count, 2, "Both annotations should be visible and packed")
        XCTAssertEqual(result[0].row, 0)
        XCTAssertEqual(result[1].row, 0,
                        "Non-overlapping annotations should share a row")
        XCTAssertEqual(result[0].feature.name, "GeneA")
        XCTAssertEqual(result[1].feature.name, "GeneB")
    }
}
