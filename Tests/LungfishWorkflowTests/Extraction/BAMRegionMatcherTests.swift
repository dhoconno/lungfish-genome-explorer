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
}
