// AlignmentFilterInspectorStateTests.swift - Tests for BAM filter inspector state
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class AlignmentFilterInspectorStateTests: XCTestCase {

    func testConfigureAlignmentFilterTracksSeedsDefaultSelectionAndOutputName() {
        let viewModel = ReadStyleSectionViewModel()

        viewModel.configureAlignmentFilterTracks([
            .init(id: "track-a", name: "Tumor Reads"),
            .init(id: "track-b", name: "Normal Reads")
        ])

        XCTAssertEqual(viewModel.alignmentFilterTrackOptions.map(\.id), ["track-a", "track-b"])
        XCTAssertEqual(viewModel.selectedAlignmentFilterSourceTrackID, "track-a")
        XCTAssertEqual(viewModel.alignmentFilterOutputTrackName, "Tumor Reads filtered")
    }

    func testDuplicateModeChangeRefreshesDefaultOutputSuffix() {
        let viewModel = ReadStyleSectionViewModel()
        viewModel.configureAlignmentFilterTracks([
            .init(id: "track-a", name: "Tumor Reads")
        ])

        viewModel.alignmentFilterDuplicateMode = .removeDuplicates

        XCTAssertEqual(viewModel.alignmentFilterOutputTrackName, "Tumor Reads deduplicated filtered")
    }

    func testConfigureAlignmentFilterTracksPreservesCustomOutputNameForValidSelection() {
        let viewModel = ReadStyleSectionViewModel()
        viewModel.configureAlignmentFilterTracks([
            .init(id: "track-a", name: "Tumor Reads"),
            .init(id: "track-b", name: "Normal Reads")
        ])
        viewModel.selectedAlignmentFilterSourceTrackID = "track-b"
        viewModel.alignmentFilterOutputTrackName = "Normal Reads curated subset"

        viewModel.configureAlignmentFilterTracks([
            .init(id: "track-a", name: "Tumor Reads"),
            .init(id: "track-b", name: "Normal Reads")
        ])

        XCTAssertEqual(viewModel.selectedAlignmentFilterSourceTrackID, "track-b")
        XCTAssertEqual(viewModel.alignmentFilterOutputTrackName, "Normal Reads curated subset")
    }

    func testMakeAlignmentFilterLaunchRequestRejectsInvalidPercentIdentityText() {
        let viewModel = ReadStyleSectionViewModel()
        viewModel.configureAlignmentFilterTracks([
            .init(id: "track-a", name: "Tumor Reads")
        ])
        viewModel.alignmentFilterMinimumPercentIdentityText = "ninety"

        XCTAssertThrowsError(try viewModel.makeAlignmentFilterLaunchRequest()) { error in
            XCTAssertEqual(
                error as? AlignmentFilterInspectorValidationError,
                .invalidMinimumPercentIdentityText("ninety")
            )
            XCTAssertEqual(error.localizedDescription, "Enter a numeric minimum percent identity value. Received 'ninety'.")
        }
    }

    func testMakeAlignmentFilterLaunchRequestRejectsOutOfRangePercentIdentity() {
        let viewModel = ReadStyleSectionViewModel()
        viewModel.configureAlignmentFilterTracks([
            .init(id: "track-a", name: "Tumor Reads")
        ])

        for invalidValue in ["-1", "100.1"] {
            viewModel.alignmentFilterMinimumPercentIdentityText = invalidValue

            XCTAssertThrowsError(try viewModel.makeAlignmentFilterLaunchRequest()) { error in
                XCTAssertEqual(
                    error as? AlignmentFilterInspectorValidationError,
                    .outOfRangeMinimumPercentIdentity(invalidValue)
                )
                XCTAssertEqual(error.localizedDescription, "Minimum percent identity must be between 0 and 100. Received '\(invalidValue)'.")
            }
        }
    }

    func testMakeAlignmentFilterLaunchRequestBuildsExactMatchIdentityFilterWhenThresholdFieldIsEmpty() throws {
        let viewModel = ReadStyleSectionViewModel()
        viewModel.configureAlignmentFilterTracks([
            .init(id: "track-a", name: "Tumor Reads")
        ])
        viewModel.alignmentFilterExactMatchOnly = true
        viewModel.alignmentFilterMinimumPercentIdentityText = ""

        let request = try viewModel.makeAlignmentFilterLaunchRequest()

        XCTAssertEqual(request.sourceTrackID, "track-a")
        XCTAssertEqual(request.filterRequest.identityFilter, .exactMatch)
    }

    func testMakeAlignmentFilterLaunchRequestBuildsFilterOnlyRequestFromValidState() throws {
        let viewModel = ReadStyleSectionViewModel()
        viewModel.configureAlignmentFilterTracks([
            .init(id: "track-b", name: "Normal Reads")
        ])
        viewModel.alignmentFilterMappedOnly = true
        viewModel.alignmentFilterPrimaryOnly = true
        viewModel.alignmentFilterMinimumMAPQ = 37
        viewModel.alignmentFilterDuplicateMode = .excludeMarked
        viewModel.alignmentFilterMinimumPercentIdentityText = "97.5"
        viewModel.alignmentFilterOutputTrackName = "Normal Reads custom"

        let request = try viewModel.makeAlignmentFilterLaunchRequest()

        XCTAssertEqual(request.sourceTrackID, "track-b")
        XCTAssertEqual(request.outputTrackName, "Normal Reads custom")
        XCTAssertEqual(
            request.filterRequest,
            AlignmentFilterRequest(
                mappedOnly: true,
                primaryOnly: true,
                minimumMAPQ: 37,
                duplicateMode: .exclude,
                identityFilter: .minimumPercentIdentity(97.5),
                region: nil
            )
        )
    }

    func testMakeAlignmentFilterLaunchRequestRejectsConflictingExactMatchAndMinimumIdentity() {
        let viewModel = ReadStyleSectionViewModel()
        viewModel.configureAlignmentFilterTracks([
            .init(id: "track-a", name: "Tumor Reads")
        ])
        viewModel.alignmentFilterExactMatchOnly = true
        viewModel.alignmentFilterMinimumPercentIdentityText = "99"

        XCTAssertThrowsError(try viewModel.makeAlignmentFilterLaunchRequest()) { error in
            XCTAssertEqual(
                error as? AlignmentFilterInspectorValidationError,
                .conflictingIdentityFilters
            )
        }
    }

    func testMakeAlignmentFilterLaunchRequestRejectsMissingSourceTrackSelection() {
        let viewModel = ReadStyleSectionViewModel()
        viewModel.configureAlignmentFilterTracks([
            .init(id: "track-a", name: "Tumor Reads")
        ])
        viewModel.selectedAlignmentFilterSourceTrackID = nil

        XCTAssertThrowsError(try viewModel.makeAlignmentFilterLaunchRequest()) { error in
            XCTAssertEqual(
                error as? AlignmentFilterInspectorValidationError,
                .missingSourceTrackSelection
            )
        }
    }
}
