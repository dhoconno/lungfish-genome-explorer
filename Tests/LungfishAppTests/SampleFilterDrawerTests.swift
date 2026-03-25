// SampleFilterDrawerTests.swift - Tests for SampleFilterState and filtering logic
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO

// MARK: - SampleFilterState Tests

final class SampleFilterStateTests: XCTestCase {

    func testInitialStateShowsAllSamples() {
        let state = SampleFilterState(
            allSampleIds: ["S1", "S2", "S3"],
            visibleSampleIds: Set(["S1", "S2", "S3"])
        )

        let metadata: [String: FASTQSampleMetadata] = [:]
        let effective = state.effectiveVisibleIds(metadata: metadata)
        XCTAssertEqual(Set(effective), Set(["S1", "S2", "S3"]))
    }

    func testHiddenSamplesExcluded() {
        let state = SampleFilterState(
            allSampleIds: ["S1", "S2", "S3"],
            visibleSampleIds: Set(["S1", "S3"])  // S2 hidden
        )

        let metadata: [String: FASTQSampleMetadata] = [:]
        let effective = state.effectiveVisibleIds(metadata: metadata)
        XCTAssertEqual(Set(effective), Set(["S1", "S3"]))
    }

    func testShowControlsFalseHidesControls() {
        var state = SampleFilterState(
            allSampleIds: ["S1", "NTC", "S2"],
            visibleSampleIds: Set(["S1", "NTC", "S2"])
        )
        state.showControls = false

        var ntcMeta = FASTQSampleMetadata(sampleName: "NTC")
        ntcMeta.sampleRole = .negativeControl

        let metadata: [String: FASTQSampleMetadata] = [
            "S1": FASTQSampleMetadata(sampleName: "S1"),
            "NTC": ntcMeta,
            "S2": FASTQSampleMetadata(sampleName: "S2"),
        ]

        let effective = state.effectiveVisibleIds(metadata: metadata)
        XCTAssertEqual(Set(effective), Set(["S1", "S2"]))
        XCTAssertFalse(effective.contains("NTC"))
    }

    func testShowControlsTrueShowsControls() {
        var state = SampleFilterState(
            allSampleIds: ["S1", "NTC"],
            visibleSampleIds: Set(["S1", "NTC"])
        )
        state.showControls = true

        var ntcMeta = FASTQSampleMetadata(sampleName: "NTC")
        ntcMeta.sampleRole = .negativeControl

        let metadata: [String: FASTQSampleMetadata] = [
            "S1": FASTQSampleMetadata(sampleName: "S1"),
            "NTC": ntcMeta,
        ]

        let effective = state.effectiveVisibleIds(metadata: metadata)
        XCTAssertEqual(Set(effective), Set(["S1", "NTC"]))
    }

    func testExtractionBlankHiddenWhenControlsHidden() {
        var state = SampleFilterState(
            allSampleIds: ["S1", "EB"],
            visibleSampleIds: Set(["S1", "EB"])
        )
        state.showControls = false

        var ebMeta = FASTQSampleMetadata(sampleName: "EB")
        ebMeta.sampleRole = .extractionBlank

        let metadata: [String: FASTQSampleMetadata] = [
            "S1": FASTQSampleMetadata(sampleName: "S1"),
            "EB": ebMeta,
        ]

        let effective = state.effectiveVisibleIds(metadata: metadata)
        XCTAssertEqual(effective, ["S1"])
    }

    func testMixedVisibilityAndControlFilter() {
        var state = SampleFilterState(
            allSampleIds: ["S1", "S2", "NTC", "POS"],
            visibleSampleIds: Set(["S1", "NTC", "POS"])  // S2 manually hidden
        )
        state.showControls = false

        var ntcMeta = FASTQSampleMetadata(sampleName: "NTC")
        ntcMeta.sampleRole = .negativeControl
        var posMeta = FASTQSampleMetadata(sampleName: "POS")
        posMeta.sampleRole = .positiveControl

        let metadata: [String: FASTQSampleMetadata] = [
            "S1": FASTQSampleMetadata(sampleName: "S1"),
            "S2": FASTQSampleMetadata(sampleName: "S2"),
            "NTC": ntcMeta,
            "POS": posMeta,
        ]

        let effective = state.effectiveVisibleIds(metadata: metadata)
        // S1 visible (test sample, checked)
        // S2 hidden (manually unchecked)
        // NTC hidden (control, showControls=false)
        // POS hidden (control, showControls=false)
        XCTAssertEqual(effective, ["S1"])
    }

    func testPreservesOrderFromAllSampleIds() {
        let state = SampleFilterState(
            allSampleIds: ["C", "A", "B"],
            visibleSampleIds: Set(["C", "A", "B"])
        )

        let metadata: [String: FASTQSampleMetadata] = [:]
        let effective = state.effectiveVisibleIds(metadata: metadata)
        XCTAssertEqual(effective, ["C", "A", "B"])  // preserves original order
    }

    func testEquality() {
        let s1 = SampleFilterState(allSampleIds: ["A"], visibleSampleIds: Set(["A"]))
        let s2 = SampleFilterState(allSampleIds: ["A"], visibleSampleIds: Set(["A"]))
        XCTAssertEqual(s1, s2)

        var s3 = s1
        s3.showControls = true
        XCTAssertNotEqual(s1, s3)
    }

    func testEmptyState() {
        let state = SampleFilterState()
        XCTAssertTrue(state.allSampleIds.isEmpty)
        XCTAssertTrue(state.visibleSampleIds.isEmpty)
        XCTAssertEqual(state.effectiveVisibleIds(metadata: [:]), [])
    }
}
