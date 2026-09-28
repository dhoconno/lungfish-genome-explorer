// MSAPairwiseIdentityColumnWidthTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
import LungfishIO

/// The MSA Inspector's Pairwise Identity value column was cut off at the
/// Inspector's default width. Its numeric columns are now sized to their
/// widest text at the current content font.
@MainActor
final class MSAPairwiseIdentityColumnWidthTests: XCTestCase {
    private func textWidth(_ text: String, pointSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .regular)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    func testValueColumnFitsSixDecimalValuesAndHeadersAtAnyTextSize() {
        for pointSize in [CGFloat(11), 13, 18] {
            let width = MSAPairwiseIdentitySection.valueColumnWidth(pointSize: pointSize)
            for sample in [MSADistanceMatrix.formatValue(0.987654), MSADistanceMatrix.formatValue(1), "p-distance", "Identity"] {
                XCTAssertGreaterThan(width, textWidth(sample, pointSize: pointSize) + 12,
                                     "\(sample) must fit at \(pointSize)pt")
            }
        }
        XCTAssertGreaterThan(
            MSAPairwiseIdentitySection.valueColumnWidth(pointSize: 18),
            MSAPairwiseIdentitySection.valueColumnWidth(pointSize: 11),
            "a larger text size widens the column"
        )
    }

    func testSitesColumnFitsTheLargestSiteCount() {
        let small = MSAPairwiseIdentitySection.sitesColumnWidth(pointSize: 11, largestSiteCount: 1_200)
        let large = MSAPairwiseIdentitySection.sitesColumnWidth(pointSize: 11, largestSiteCount: 12_345_678)
        XCTAssertGreaterThan(small, textWidth("99999", pointSize: 11) + 12)
        XCTAssertGreaterThan(large, textWidth("12345678", pointSize: 11) + 12)
    }
}
