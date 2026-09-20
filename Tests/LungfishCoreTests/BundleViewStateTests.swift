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
            hiddenVariantTrackIDs: ["ivar", "freebayes"],
            sampleDisplayState: sampleState
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BundleViewState.self, from: data)

        XCTAssertEqual(decoded.annotationFilterText, "polymerase")
        XCTAssertEqual(decoded.variantFilterText, "QUAL > 100")
        XCTAssertEqual(decoded.hiddenVariantTrackIDs, ["ivar", "freebayes"])
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
        XCTAssertEqual(decoded.hiddenVariantTrackIDs, [])
        XCTAssertNil(decoded.sampleDisplayState)
    }

    func testLegacyAllVisibleAnnotationTypesIncludeNewORFTypes() throws {
        let legacyAllVisibleTypes = Set(AnnotationType.allCases).subtracting([.orf, .translation])
        let legacyState = BundleViewState(visibleAnnotationTypes: legacyAllVisibleTypes)
        let data = try JSONEncoder().encode(legacyState)

        let decoded = try JSONDecoder().decode(BundleViewState.self, from: data)

        XCTAssertTrue(decoded.visibleAnnotationTypes?.contains(.orf) ?? false)
        XCTAssertTrue(decoded.visibleAnnotationTypes?.contains(.translation) ?? false)
    }

    func testDefaultHasNoHiddenVariantTracks() {
        XCTAssertEqual(BundleViewState.default.hiddenVariantTrackIDs, [])
    }

    func testAllVariantTrackIDsCanBePersistedAsHidden() throws {
        let state = BundleViewState(hiddenVariantTrackIDs: ["track-a", "track-b"])

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BundleViewState.self, from: data)

        XCTAssertEqual(decoded.hiddenVariantTrackIDs, ["track-a", "track-b"])
    }
}
