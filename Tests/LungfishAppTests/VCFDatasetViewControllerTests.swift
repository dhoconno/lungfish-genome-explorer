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
}

// MARK: - Test Helpers

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        if let typed = self as? T {
            return typed
        }
        for subview in subviews {
            if let match = subview.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private func waitUntilCondition(
    timeout: TimeInterval = 2.0,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), file: file, line: line)
}
