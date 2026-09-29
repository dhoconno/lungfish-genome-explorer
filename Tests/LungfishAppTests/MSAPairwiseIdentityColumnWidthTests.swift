// MSAPairwiseIdentityColumnWidthTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
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

    /// Preview 2026.9.57: at the Inspector's default width the "Identity"
    /// header was clipped, the Sites column sat past the right edge and
    /// "Export TSV…" was cut off. The table and its controls must fit the
    /// Inspector's content width down to its minimum.
    func testTableFitsTheInspectorsMinimumContentWidth() {
        for pointSize in [CGFloat(11), 13] {
            XCTAssertLessThanOrEqual(
                MSAPairwiseIdentitySection.minimumTableWidth(pointSize: pointSize, largestSiteCount: 2_953),
                210,
                "at \(pointSize)pt: the Inspector's minimum content width is about 210 pt"
            )
        }
    }

    func testSectionFitsDefaultAndMinimumInspectorWidths() async {
        let names = [
            "LR699574.1_Mamu-A1_001_01_01_01_Macaca_mulatta_genomic_DNA",
            "LR701148.1_Mamu-A1_001_01_01_02_Macaca_mulatta_genomic_DNA",
            "LR699565.1_Mamu-A1_002_01_01_01_Macaca_mulatta_genomic_DNA",
        ]
        let records = names.enumerated().map { index, name in
            MSAAlignedRecord(name: name, sequence: index == 0 ? "ACGTACGTAC" : "ACGTACGAAC")
        }
        let model = MSAPairwiseIdentityInspectorModel(
            bundleURL: URL(fileURLWithPath: "/tmp/panel.lungfishmsa"),
            recordLoader: { _ in records }
        )
        model.onExportRequested = { _ in }
        await model.compute()
        XCTAssertEqual(model.status, .ready)

        let host = NSHostingController(rootView: MSAPairwiseIdentitySection(
            model: model,
            isExpanded: .constant(true)
        ))
        // Content widths of the Inspector at its default (340) and minimum
        // (260) widths, after the Inspector's own padding.
        for width in [CGFloat(290), 210] {
            let size = host.sizeThatFits(in: CGSize(width: width, height: 2_000))
            XCTAssertLessThanOrEqual(size.width, width + 0.5, "the section overflows \(width) pt")
        }
    }
}
