// NaoMgsImportOptimizationTests.swift — Tests for NAO-MGS import optimization
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishIO
@testable import LungfishWorkflow

struct NaoMgsImportOptimizationTests {

    // MARK: - Line Progress Callback

    @Test
    func parseVirusHitsCallsLineProgressCallback() async throws {
        let url = TestFixtures.naomgs.virusHitsTsvGz
        let parser = NaoMgsResultParser()

        // Use a lock-protected counter to avoid Sendable mutation errors in Swift 6
        final class Counter: @unchecked Sendable {
            var values: [Int] = []
            func append(_ v: Int) { values.append(v) }
        }
        let counter = Counter()

        let hits = try await parser.parseVirusHits(at: url) { lineCount in
            counter.append(lineCount)
        }

        #expect(hits.count == 35, "Fixture has 35 data rows")
        #expect(!counter.values.isEmpty, "lineProgress should have been called at least once")
        // Final reported count should be >= 35 (header + 35 data lines = 36 total lines)
        #expect(counter.values.last! >= 35)
    }

    @Test
    func parseVirusHitsWorksWithoutCallback() async throws {
        let url = TestFixtures.naomgs.virusHitsTsvGz
        let parser = NaoMgsResultParser()

        // Existing signature still works with no callback
        let hits = try await parser.parseVirusHits(at: url)
        #expect(hits.count == 35)
    }

    // MARK: - Top-5 Accession Filtering

    @Test
    func selectTopAccessionsPerTaxonFiltersCorrectly() async throws {
        let url = TestFixtures.naomgs.virusHitsTsvGz
        let parser = NaoMgsResultParser()
        let hits = try await parser.parseVirusHits(at: url)

        let selected = MetagenomicsImportService.selectTopAccessionsPerTaxon(
            hits: hits,
            maxPerTaxon: 5
        )

        // Taxon 28875 has 9 accessions — only top 5 by hit count should be kept
        // Taxon 10941 has 3 — all kept
        // Taxon 2748378 has 2 — all kept
        // Taxon 1187973 has 1 — kept
        // Total unique: 11
        #expect(selected.count == 11, "Expected 11 unique accessions, got \(selected.count): \(selected)")

        // Taxon 28875: KR705168.1 has 4 hits (highest), must be included
        #expect(selected.contains("KR705168.1"))

        // Bottom accessions for taxon 28875 (1 hit each) should NOT be included
        let bottom28875 = ["JN258371.1", "KJ752320.1", "KU356637.1"]
        let bottomIncluded = bottom28875.filter { selected.contains($0) }
        #expect(bottomIncluded.isEmpty, "Bottom-ranked 28875 accessions should be filtered out: \(bottomIncluded)")

        // All accessions for taxa with <=5 accessions should be present
        #expect(selected.contains("MH617353.1"), "2748378 accession should be kept")
        #expect(selected.contains("MH617681.1"), "2748378 accession should be kept")
        #expect(selected.contains("LC105580.1"), "10941 accession should be kept")
        #expect(selected.contains("LC105591.1"), "10941 accession should be kept")
        #expect(selected.contains("KP198630.1"), "10941 accession should be kept")
        #expect(selected.contains("JQ776552.1"), "1187973 accession should be kept")
    }
}
