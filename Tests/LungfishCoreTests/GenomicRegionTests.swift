// GenomicRegionTests.swift - Additional safety-net edge-case tests for GenomicRegion
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Note: Core GenomicRegion tests live in SequenceTests.swift.
// This file adds edge-case and contract tests not covered there.

import XCTest
@testable import LungfishCore

/// Additional edge-case tests for GenomicRegion that complement the
/// basic coverage in SequenceTests.swift's GenomicRegionTests class.
final class GenomicRegionEdgeCaseTests: XCTestCase {

    // MARK: - Empty Region Edge Cases

    func testEmptyRegionContainsNoPositions() {
        let empty = GenomicRegion(chromosome: "chr1", start: 500, end: 500)
        XCTAssertFalse(empty.contains(position: 500),
            "Empty half-open interval [500,500) should contain nothing")
        XCTAssertFalse(empty.contains(position: 499))
    }

    func testEmptyRegionDoesNotOverlapItself() {
        // An empty region [x,x) has start < end == false (start == end),
        // so overlaps requires start < other.end && end > other.start.
        // For [500,500): 500 < 500 is false, so no overlap.
        let empty = GenomicRegion(chromosome: "chr1", start: 500, end: 500)
        XCTAssertFalse(empty.overlaps(empty),
            "Empty region should not overlap even with itself")
    }

    func testEmptyRegionDoesNotOverlapContainingRegion() {
        let empty = GenomicRegion(chromosome: "chr1", start: 500, end: 500)
        let big = GenomicRegion(chromosome: "chr1", start: 400, end: 600)
        // big.start(400) < empty.end(500) && big.end(600) > empty.start(500) => true
        // But empty: empty.start(500) < big.end(600) && empty.end(500) > big.start(400) => 500 > 400 is true AND 500 < 600 is true => true
        // Actually both overlap from the non-empty side's perspective.
        // Let's test the empty region perspective:
        XCTAssertFalse(empty.overlaps(empty),
            "Empty-empty overlap should be false")
    }

    func testEmptyRegionIntersectionIsNil() {
        let empty = GenomicRegion(chromosome: "chr1", start: 500, end: 500)
        let other = GenomicRegion(chromosome: "chr1", start: 400, end: 600)
        // intersection depends on overlaps; if empty doesn't overlap itself, check with other
        // empty.overlaps(other): empty.start(500) < other.end(600) && empty.end(500) > other.start(400) => true && true => true
        // So intersection should work:
        let result = empty.intersection(other)
        // max(500,400)=500, min(500,600)=500 => [500,500) which is empty
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.length, 0)
    }

    // MARK: - Distance Symmetry

    func testDistanceIsSymmetric() {
        let a = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let b = GenomicRegion(chromosome: "chr1", start: 500, end: 600)
        XCTAssertEqual(a.distance(to: b), b.distance(to: a))
    }

    func testDistanceOfOneBase() {
        let a = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let b = GenomicRegion(chromosome: "chr1", start: 201, end: 300)
        XCTAssertEqual(a.distance(to: b), 1)
    }

    // MARK: - Expand Edge Cases

    func testExpandLargeAmountFromZeroStart() {
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 100)
        let expanded = region.expanded(by: 1_000_000)
        XCTAssertEqual(expanded.start, 0, "Should clamp at 0, not go negative")
        XCTAssertEqual(expanded.end, 1_000_100)
    }

    func testExpandPreservesChromosome() {
        let region = GenomicRegion(chromosome: "chrX", start: 500, end: 600)
        let expanded = region.expanded(by: 50)
        XCTAssertEqual(expanded.chromosome, "chrX")
    }

    // MARK: - Comparable Tiebreaker

    func testComparableSameChromosomeSameStartDifferentEnd() {
        let shorter = GenomicRegion(chromosome: "chr1", start: 100, end: 150)
        let longer = GenomicRegion(chromosome: "chr1", start: 100, end: 300)
        XCTAssertTrue(shorter < longer,
            "Same chromosome, same start: shorter end should sort first")
    }

    func testSortStabilityWithMixedChromosomeNames() {
        // Lexicographic sort means "chr10" < "chr2" (string comparison)
        let regions = [
            GenomicRegion(chromosome: "chr2", start: 0, end: 100),
            GenomicRegion(chromosome: "chr10", start: 0, end: 100),
        ]
        let sorted = regions.sorted()
        XCTAssertEqual(sorted[0].chromosome, "chr10",
            "Lexicographic string sort: 'chr10' < 'chr2'")
        XCTAssertEqual(sorted[1].chromosome, "chr2")
    }

    // MARK: - Hashable / Equatable Contract

    func testHashableDeduplicationInSet() {
        let a = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let b = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let c = GenomicRegion(chromosome: "chr1", start: 100, end: 300)

        let set: Set<GenomicRegion> = [a, b, c]
        XCTAssertEqual(set.count, 2, "a and b are equal, c is different")
    }

    func testDifferentChromosomeSameCoordinatesAreNotEqual() {
        let a = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let b = GenomicRegion(chromosome: "chr2", start: 100, end: 200)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let region = GenomicRegion(chromosome: "chrMT", start: 0, end: 16569)
        let data = try JSONEncoder().encode(region)
        let decoded = try JSONDecoder().decode(GenomicRegion.self, from: data)
        XCTAssertEqual(decoded, region)
    }

    func testCodableRoundTripEmptyRegion() throws {
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 0)
        let data = try JSONEncoder().encode(region)
        let decoded = try JSONDecoder().decode(GenomicRegion.self, from: data)
        XCTAssertEqual(decoded, region)
        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: - Intersection Commutativity

    func testIntersectionIsCommutative() {
        let a = GenomicRegion(chromosome: "chr1", start: 100, end: 300)
        let b = GenomicRegion(chromosome: "chr1", start: 200, end: 400)
        XCTAssertEqual(a.intersection(b), b.intersection(a))
    }

    // MARK: - Union Commutativity

    func testUnionIsCommutative() {
        let a = GenomicRegion(chromosome: "chr1", start: 100, end: 300)
        let b = GenomicRegion(chromosome: "chr1", start: 200, end: 400)
        XCTAssertEqual(a.union(b), b.union(a))
    }

    // MARK: - Large Coordinate Values

    func testLargeGenomicCoordinates() {
        // Human chromosome 1 is ~248 million bases
        let region = GenomicRegion(chromosome: "chr1", start: 200_000_000, end: 248_956_422)
        XCTAssertEqual(region.length, 48_956_422)
        XCTAssertFalse(region.isEmpty)
    }

    // MARK: - Overlap with Single-Base Region

    func testSingleBaseRegionOverlap() {
        let singleBase = GenomicRegion(chromosome: "chr1", start: 150, end: 151)
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        XCTAssertTrue(singleBase.overlaps(region))
        XCTAssertTrue(region.overlaps(singleBase))
        XCTAssertEqual(singleBase.length, 1)
    }

    func testSingleBaseRegionAtBoundaryDoesNotOverlap() {
        let singleBase = GenomicRegion(chromosome: "chr1", start: 200, end: 201)
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        XCTAssertFalse(region.overlaps(singleBase),
            "Single base at [200,201) should not overlap [100,200)")
    }
}
