// BAMRegionMatcherTests.swift - Tests for BAMRegionMatcher multi-strategy matching
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import LungfishWorkflow

@Suite("BAMRegionMatcher")
struct BAMRegionMatcherTests {

    @Test("Exact match finds matching regions")
    func exactMatch() {
        let bamRefs = ["NC_005831.2", "NC_001477.1", "NC_012532.1"]
        let result = BAMRegionMatcher.match(regions: ["NC_005831.2", "NC_001477.1"], againstReferences: bamRefs)
        #expect(result.matchedRegions.sorted() == ["NC_001477.1", "NC_005831.2"])
        #expect(result.unmatchedRegions.isEmpty)
        #expect(result.strategy == .exact)
    }

    @Test("Prefix match handles version differences")
    func prefixMatch() {
        let bamRefs = ["NC_005831.2_complete_genome", "NC_001477.1_segment_L"]
        let result = BAMRegionMatcher.match(regions: ["NC_005831.2"], againstReferences: bamRefs)
        #expect(result.matchedRegions == ["NC_005831.2_complete_genome"])
        #expect(result.strategy == .prefix)
    }

    @Test("Contains match finds embedded accessions")
    func containsMatch() {
        let bamRefs = ["ref|NC_005831.2|complete", "ref|NC_001477.1|partial"]
        let result = BAMRegionMatcher.match(regions: ["NC_005831.2"], againstReferences: bamRefs)
        #expect(result.matchedRegions == ["ref|NC_005831.2|complete"])
        #expect(result.strategy == .contains)
    }

    @Test("Fallback returns all refs when nothing matches")
    func fallback() {
        let bamRefs = ["contig_1", "contig_2", "contig_3"]
        let result = BAMRegionMatcher.match(regions: ["NC_005831.2"], againstReferences: bamRefs)
        #expect(result.matchedRegions.sorted() == ["contig_1", "contig_2", "contig_3"])
        #expect(result.strategy == .fallbackAll)
    }

    @Test("Empty refs returns noBAM strategy")
    func emptyRefs() {
        let result = BAMRegionMatcher.match(regions: ["NC_005831.2"], againstReferences: [])
        #expect(result.matchedRegions.isEmpty)
        #expect(result.strategy == .noBAM)
    }

    @Test("Deduplicates matched regions")
    func deduplication() {
        let bamRefs = ["NC_005831.2"]
        let result = BAMRegionMatcher.match(regions: ["NC_005831.2", "NC_005831.2"], againstReferences: bamRefs)
        #expect(result.matchedRegions.count == 1)
    }

    // MARK: - samtools coordinate regions (R3)

    @Test("A coordinate region on a named reference passes through to samtools unchanged")
    func coordinateRegionOnAnExactReference() {
        let bamRefs = ["MT192765.1", "chr1"]
        let regions = ["MT192765.1:1-3000", "chr1:1,001-2,000", "chr1:500", "chr1:500-", "chr1:-200"]
        let result = BAMRegionMatcher.match(regions: regions, againstReferences: bamRefs)
        #expect(result.matchedRegions == regions)
        #expect(result.unmatchedRegions.isEmpty)
        #expect(result.strategy == .exact)
        #expect(result.coordinateRegions == regions)
    }

    @Test("The brace form names a reference whose own name holds a colon")
    func braceFormForAReferenceNameWithAColon() {
        let bamRefs = ["HLA-A*01:01:01:01", "chr1"]
        let result = BAMRegionMatcher.match(
            regions: ["{HLA-A*01:01:01:01}:10-20", "{chr1}"],
            againstReferences: bamRefs
        )
        #expect(result.matchedRegions == ["{HLA-A*01:01:01:01}:10-20", "{chr1}"])
        #expect(result.strategy == .exact)
        #expect(result.coordinateRegions == ["{HLA-A*01:01:01:01}:10-20", "{chr1}"])
    }

    @Test("A reference name that holds a colon still matches as a whole reference")
    func wholeReferenceNameWithAColon() {
        let bamRefs = ["HLA-A*01:01:01:01"]
        let result = BAMRegionMatcher.match(regions: ["HLA-A*01:01:01:01"], againstReferences: bamRefs)
        #expect(result.matchedRegions == ["HLA-A*01:01:01:01"])
        #expect(result.strategy == .exact)
        #expect(result.coordinateRegions.isEmpty)
    }

    @Test("A coordinate region on a reference the BAM lacks is not matched")
    func coordinateRegionOnAnUnknownReference() {
        let bamRefs = ["chr1", "chr2"]
        let result = BAMRegionMatcher.match(regions: ["chr9:1-50", "chr1:abc"], againstReferences: bamRefs)
        #expect(result.strategy == .fallbackAll)
        #expect(result.unmatchedRegions == ["chr9:1-50", "chr1:abc"])
    }

    @Test("Coordinate and whole-reference regions match together")
    func mixedCoordinateAndWholeReferenceRegions() {
        let bamRefs = ["MT192765.1", "NC_045512.2"]
        let result = BAMRegionMatcher.match(
            regions: ["NC_045512.2", "MT192765.1:100-200"],
            againstReferences: bamRefs
        )
        #expect(result.matchedRegions == ["NC_045512.2", "MT192765.1:100-200"])
        #expect(result.strategy == .exact)
        #expect(result.coordinateRegions == ["MT192765.1:100-200"])
    }

    @Test("Whole-reference matches carry no coordinate regions, so their samtools argv is unchanged")
    func nameMatchesCarryNoCoordinateRegions() {
        let exact = BAMRegionMatcher.match(regions: ["NC_005831.2"], againstReferences: ["NC_005831.2"])
        let prefix = BAMRegionMatcher.match(regions: ["NC_005831.2"], againstReferences: ["NC_005831.2_complete_genome"])
        let contains = BAMRegionMatcher.match(regions: ["NC_005831.2"], againstReferences: ["ref|NC_005831.2|complete"])
        let fallback = BAMRegionMatcher.match(regions: ["NC_005831.2"], againstReferences: ["contig_1"])
        for result in [exact, prefix, contains, fallback] {
            #expect(result.coordinateRegions.isEmpty)
        }
    }
}
