// TaxTriageConfidenceCellViewTests.swift - Confidence-cell palette coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishTaxTriageUI
import LungfishKit

@MainActor
final class TaxTriageConfidenceCellViewTests: XCTestCase {

    func testPaletteUsesSharedTaxTriageConfidenceThresholds() {
        XCTAssertTrue(TaxTriageConfidencePalette.color(for: 0.80).isEqual(NSColor.systemGreen))
        XCTAssertTrue(TaxTriageConfidencePalette.color(for: 0.40).isEqual(NSColor.systemYellow))
        XCTAssertTrue(TaxTriageConfidencePalette.color(for: 0.39).isEqual(NSColor.lungfishDanger))
    }
}
