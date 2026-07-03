// VCFDatasetViewControllerTests.swift - Debounce tests for VCF variant browser filter
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class VCFDatasetViewControllerTests: XCTestCase {

    // MARK: - Helpers

    private func makeVariants() -> [LungfishIO.VCFVariant] {
        [
            LungfishIO.VCFVariant(
                id: "v1", chromosome: "chr1", position: 100,
                ref: "A", alt: ["G"], quality: 60, filter: "PASS", info: [:]
            ),
            LungfishIO.VCFVariant(
                id: "v2", chromosome: "chr2", position: 200,
                ref: "C", alt: ["T"], quality: 50, filter: "PASS", info: [:]
            ),
            LungfishIO.VCFVariant(
                id: "v3", chromosome: "chr1", position: 150,
                ref: "A", alt: ["G"], quality: 55, filter: "PASS", info: [:]
            ),
        ]
    }

    private func makeSummary(variantCount: Int = 3) -> VCFSummary {
        let header = VCFHeader()
        return VCFSummary(
            header: header,
            variantCount: variantCount,
            chromosomes: ["chr1", "chr2"],
            maxPositionPerChromosome: ["chr1": 150, "chr2": 200],
            variantTypes: ["SNP": variantCount],
            hasSampleColumns: false,
            inferredReference: nil,
            qualityStats: VCFSummary.QualityStats(min: 50, max: 60, mean: 55, count: variantCount),
            filterCounts: ["PASS": variantCount]
        )
    }

    // MARK: - Debounce Tests

    func testUserFilterInputIsDebounced() async throws {
        let vc = VCFDatasetViewController()
        _ = vc.view // force loadView
        let variants = makeVariants()
        vc.configure(summary: makeSummary(), variants: variants)

        let field = try XCTUnwrap(vc.view.firstDescendant(of: NSSearchField.self))
        field.stringValue = "chr1"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)

        // Synchronous: still all 3 (debounce not yet fired).
        XCTAssertEqual(vc.displayedVariantCountForTesting, 3)

        try await waitUntilCondition { vc.displayedVariantCountForTesting == 2 }
        XCTAssertEqual(vc.displayedVariantCountForTesting, 2)
    }

    func testClearingUserFilterAppliesImmediately() throws {
        let vc = VCFDatasetViewController()
        _ = vc.view
        let variants = makeVariants()
        vc.configure(summary: makeSummary(), variants: variants)

        // Set filter programmatically (immediate)
        vc.setFilterText("chr1")
        XCTAssertEqual(vc.displayedVariantCountForTesting, 2)

        // Clear via delegate notification (should apply immediately — no debounce for empty)
        let field = try XCTUnwrap(vc.view.firstDescendant(of: NSSearchField.self))
        field.stringValue = ""
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)

        XCTAssertEqual(vc.displayedVariantCountForTesting, 3)
    }

    func testProgrammaticSetFilterTextAppliesImmediately() {
        let vc = VCFDatasetViewController()
        _ = vc.view
        let variants = makeVariants()
        vc.configure(summary: makeSummary(), variants: variants)

        vc.setFilterText("chr1")
        XCTAssertEqual(vc.displayedVariantCountForTesting, 2)
    }

    // MARK: - Search-Key Precompute Parity Tests

    /// Reference implementation of the old per-apply search-key construction.
    /// Filtering against the precomputed keys must return byte-identical results.
    private func legacyMatches(_ variant: LungfishIO.VCFVariant, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty { return true }
        let posStr = "\(variant.position)"
        let combined = "\(variant.chromosome) \(posStr) \(variant.ref) \(variant.alt.joined(separator: ","))".lowercased()
        return combined.contains(trimmed)
    }

    func testPrecomputedFilterMatchesLegacyResults() {
        let vc = VCFDatasetViewController()
        _ = vc.view
        let variants = makeVariants()
        vc.configure(summary: makeSummary(), variants: variants)

        // Representative queries: chromosome, position substring, ref/alt, mixed case,
        // whitespace-padded, no-match, and empty.
        let queries = ["chr1", "chr2", "20", "15", "10", "A", "G", "t", "  CHR1  ", "zzz", "", "chr1 100"]
        for query in queries {
            let expected = variants.filter { legacyMatches($0, query: query) }
            vc.setFilterText(query)
            let actual = vc.testDisplayedVariants
            XCTAssertEqual(actual.map(\.id), expected.map(\.id),
                           "Filter results for query \"\(query)\" must match legacy semantics")
        }
    }

    func testSearchKeysComputedOnceAtConfigureNotPerApply() {
        let vc = VCFDatasetViewController()
        _ = vc.view
        let variants = makeVariants()

        vc.configure(summary: makeSummary(), variants: variants)
        let buildsAfterConfigure = vc.searchKeyBuildCountForTesting
        XCTAssertEqual(buildsAfterConfigure, 1,
                       "Search keys should be built exactly once at configure()")

        // Multiple filter applies must not rebuild the keys.
        vc.setFilterText("chr1")
        vc.setFilterText("chr2")
        vc.setFilterText("")
        XCTAssertEqual(vc.searchKeyBuildCountForTesting, buildsAfterConfigure,
                       "applyFilter() must not rebuild search keys")
    }

    func testRapidSearchInputCoalescesToOneFilterApply() async throws {
        let vc = VCFDatasetViewController()
        _ = vc.view
        let variants = makeVariants()
        vc.configure(summary: makeSummary(), variants: variants)

        let countAfterConfigure = vc.applyFilterCount   // typically 1 from configure()

        let field = try XCTUnwrap(vc.view.firstDescendant(of: NSSearchField.self))

        // Fire two rapid changes within the same debounce window.
        field.stringValue = "chr"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        field.stringValue = "chr1"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)

        // Synchronously: no extra applyFilter should have run yet.
        XCTAssertEqual(vc.applyFilterCount, countAfterConfigure,
                       "applyFilter() must not run synchronously during debounce window")

        // After debounce settles we expect exactly ONE additional application,
        // reflecting only the final value "chr1" (2 matches — chr1 at 100 and 150).
        try await waitUntilCondition { vc.applyFilterCount == countAfterConfigure + 1 }

        XCTAssertEqual(vc.applyFilterCount, countAfterConfigure + 1,
                       "Two rapid keystrokes should coalesce into exactly one applyFilter() call")
        XCTAssertEqual(vc.displayedVariantCountForTesting, 2,
                       "Final settled result should match the last search value (chr1 → 2 variants)")
    }
}

// MARK: - Test Helpers
// firstDescendant(of:) and waitUntilCondition(_:) live in XCTestUISupport.swift (module-wide).
