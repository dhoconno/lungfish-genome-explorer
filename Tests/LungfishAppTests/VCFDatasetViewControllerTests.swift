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

    // MARK: - Empty-variants edge case (Phase 3 gate)

    /// Regression: configure(summary:variants:[]) must not crash, must leave displayedCount==0,
    /// and must safely build zero search keys (guard against nil-index in applyFilter loop).
    func testConfigureWithEmptyVariantsIsNoopSafe() throws {
        let vc = VCFDatasetViewController()
        _ = vc.view

        // configure with an empty array — must not crash
        vc.configure(summary: makeSummary(variantCount: 0), variants: [])
        XCTAssertEqual(vc.displayedVariantCountForTesting, 0,
                       "displayedVariantCount must be 0 after configure with empty variants")

        // applyFilter over an empty set must also be safe
        vc.setFilterText("chr1")
        XCTAssertEqual(vc.displayedVariantCountForTesting, 0,
                       "filter over empty variants must still yield 0")

        vc.setFilterText("")
        XCTAssertEqual(vc.displayedVariantCountForTesting, 0,
                       "clearing filter over empty variants must still yield 0")

        #if DEBUG
        // buildSearchKeys([]) must have been called exactly once at configure, not again at filter
        XCTAssertEqual(vc.searchKeyBuildCountForTesting, 1,
                       "search keys must be built exactly once even when variants is empty")
        #endif
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

    // MARK: - Chip Cancels Pending Debounce

    /// Tapping a type chip while a debounced text-filter is pending must result
    /// in exactly one applyFilter() call (from the chip), not two (chip + debounce).
    func testChipTapCancelsPendingDebouncedTextFilter() async throws {
        let vc = VCFDatasetViewController()
        _ = vc.view
        let variants = makeVariants()
        vc.configure(summary: makeSummary(), variants: variants)

        let countAfterConfigure = vc.applyFilterCount

        // Trigger a debounced text-filter without waiting for it to fire.
        let field = try XCTUnwrap(vc.view.firstDescendant(of: NSSearchField.self))
        field.stringValue = "chr"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)

        // Synchronously, the debounce task is pending and applyFilter hasn't fired yet.
        XCTAssertEqual(vc.applyFilterCount, countAfterConfigure,
                       "Precondition: debounce must still be pending")

        // Simulate a chip tap by finding the SNP chip (tag 0) among the vc's chip
        // buttons. The type-chips bar is view.subviews[1] (added second in loadView).
        // We find buttons by recursing into that subview and selecting by tag so
        // the test is insensitive to layout changes inside the bar.
        let typeChipsBar = vc.view.subviews[1]
        let chipButtons = typeChipsBar.subviews.compactMap { $0 as? NSButton }
        // tag -1 is "All"; tag 0 is the first type chip (SNP in a single-type summary).
        let snpChip = try XCTUnwrap(chipButtons.first(where: { $0.tag == 0 }),
                                    "Expected an SNP chip (tag 0) in the type chips bar")
        // Fire via NSApp.sendAction to mirror a real user click on the button.
        NSApp.sendAction(snpChip.action!, to: snpChip.target, from: snpChip)

        // After the chip tap the filter must have fired exactly once more (the chip's call).
        XCTAssertEqual(vc.applyFilterCount, countAfterConfigure + 1,
                       "Chip tap must trigger exactly one applyFilter(), not zero")

        // Wait well past the debounce window; the cancelled task must NOT fire a second apply.
        let countAfterChip = vc.applyFilterCount
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(vc.applyFilterCount, countAfterChip,
                       "Cancelled debounce task must not fire a second applyFilter() after the chip tap")
    }
}

// MARK: - Test Helpers
// firstDescendant(of:) and waitUntilCondition(_:) live in XCTestUISupport.swift (module-wide).
