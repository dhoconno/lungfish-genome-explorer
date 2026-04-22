// AlignmentFilterInspectorStateTests.swift - Tests for BAM filter inspector state
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

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

    func testMakeAlignmentFilterLaunchRequestRejectsInvalidPercentIdentityText() {
        let viewModel = ReadStyleSectionViewModel()
        viewModel.configureAlignmentFilterTracks([
            .init(id: "track-a", name: "Tumor Reads")
        ])
        viewModel.alignmentFilterMinimumPercentIdentityText = "ninety"

        XCTAssertThrowsError(try viewModel.makeAlignmentFilterLaunchRequest()) { error in
            XCTAssertEqual(
                error as? AlignmentFilterInspectorValidationError,
                .invalidMinimumPercentIdentity("ninety")
            )
        }
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
