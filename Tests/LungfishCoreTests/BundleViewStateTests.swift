// BundleViewStateTests.swift - Tests for portable per-bundle viewer state
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class BundleViewStateTests: XCTestCase {

    func testRoundTripPersistsFilterTextAndSampleDisplayState() throws {
        var sampleState = SampleDisplayState(showGenotypeRows: false, rowHeight: 18)
        sampleState.hiddenSamples = ["blank-control"]

        let state = BundleViewState(
            annotationFilterText: "polymerase",
            variantFilterText: "QUAL > 100",
            sampleDisplayState: sampleState
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BundleViewState.self, from: data)

        XCTAssertEqual(decoded.annotationFilterText, "polymerase")
        XCTAssertEqual(decoded.variantFilterText, "QUAL > 100")
        XCTAssertEqual(decoded.sampleDisplayState, sampleState)
    }

    func testBackwardCompatibleDecodeDefaultsNewSessionStateFields() throws {
        let json = """
        {
          "annotationHeight" : 16,
          "annotationSpacing" : 2,
          "showAnnotations" : true,
          "showVariants" : true,
          "translationColorScheme" : "zappo",
          "isRNAMode" : false,
          "typeColorOverrides" : []
        }
        """

        let decoded = try JSONDecoder().decode(BundleViewState.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.annotationFilterText, "")
        XCTAssertEqual(decoded.variantFilterText, "")
        XCTAssertNil(decoded.sampleDisplayState)
    }
}
