// BundleDisplayLabelTests.swift - Tests for the shared bundle-name/contig-id
// display-string helper used by the mapping viewer selector cells and track
// header (Item 2, mapping-viewer-fixes 2026-08-09).
//
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class BundleDisplayLabelTests: XCTestCase {

    // MARK: - secondaryLine

    func testSecondaryLineReturnsContigNameWhenDifferentFromBundleName() {
        let secondary = BundleDisplayLabel.secondaryLine(
            bundleName: "SARS-CoV-2 Reference",
            contigName: "NC_078297"
        )
        XCTAssertEqual(secondary, "NC_078297")
    }

    func testSecondaryLineOmittedWhenContigNameEqualsBundleName() {
        let secondary = BundleDisplayLabel.secondaryLine(
            bundleName: "NC_078297",
            contigName: "NC_078297"
        )
        XCTAssertNil(secondary)
    }

    func testSecondaryLineAppendsFastaDescriptionWhenPresent() {
        let secondary = BundleDisplayLabel.secondaryLine(
            bundleName: "Macaque MHC Reference",
            contigName: "NC_041754.1",
            fastaDescription: "Macaca mulatta chromosome 1"
        )
        XCTAssertEqual(secondary, "NC_041754.1 (Macaca mulatta chromosome 1)")
    }

    func testSecondaryLineIgnoresEmptyFastaDescription() {
        let secondary = BundleDisplayLabel.secondaryLine(
            bundleName: "SARS-CoV-2 Reference",
            contigName: "NC_078297",
            fastaDescription: ""
        )
        XCTAssertEqual(secondary, "NC_078297")
    }

    // MARK: - trackHeaderLabel

    func testTrackHeaderLabelUsesBundleNameAloneForSingleContig() {
        let label = BundleDisplayLabel.trackHeaderLabel(
            bundleName: "SARS-CoV-2 Reference",
            contigName: "NC_078297",
            isSingleContig: true
        )
        XCTAssertEqual(label, "SARS-CoV-2 Reference")
    }

    func testTrackHeaderLabelAppendsParentheticalContigForMultiContig() {
        let label = BundleDisplayLabel.trackHeaderLabel(
            bundleName: "Macaque MHC Reference",
            contigName: "NC_041754.1",
            isSingleContig: false
        )
        XCTAssertEqual(label, "Macaque MHC Reference (NC_041754.1)")
    }

    func testTrackHeaderLabelPrefersFastaDescriptionOverContigNameForMultiContig() {
        let label = BundleDisplayLabel.trackHeaderLabel(
            bundleName: "Macaque MHC Reference",
            contigName: "NC_041754.1",
            fastaDescription: "Macaca mulatta chromosome 1",
            isSingleContig: false
        )
        XCTAssertEqual(label, "Macaque MHC Reference (Macaca mulatta chromosome 1)")
    }

    func testDisplayLabelHelperUsesNoEmDash() {
        let secondary = BundleDisplayLabel.secondaryLine(
            bundleName: "Macaque MHC Reference",
            contigName: "NC_041754.1",
            fastaDescription: "Macaca mulatta chromosome 1"
        )
        let header = BundleDisplayLabel.trackHeaderLabel(
            bundleName: "Macaque MHC Reference",
            contigName: "NC_041754.1",
            fastaDescription: "Macaca mulatta chromosome 1",
            isSingleContig: false
        )
        XCTAssertFalse((secondary ?? "").contains("\u{2014}"), "secondary line must not contain an em dash")
        XCTAssertFalse(header.contains("\u{2014}"), "track header label must not contain an em dash")
    }
}
