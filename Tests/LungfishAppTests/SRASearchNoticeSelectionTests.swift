// SRASearchNoticeSelectionTests.swift - The SRA search notice no longer hides the selection count
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore

/// Finding F5-N7: an SRA search that one archive failed shows a notice, such
/// as "ENA returned HTTP 500 (server error). Results from NCBI are shown.",
/// which the search keeps in `errorMessage`. The dialog's status line showed
/// the notice instead of "N selected" until a download started. The count
/// now stands before the notice.
@MainActor
final class SRASearchNoticeSelectionTests: XCTestCase {

    private static let notice = "ENA returned HTTP 500 (server error). Results from NCBI are shown."

    func testTheNoticeStaysBesideTheSelectionCount() {
        let state = DatabaseSearchDialogState(initialDestination: .sraRuns)
        state.sraRunsViewModel.errorMessage = Self.notice
        XCTAssertEqual(DatabaseSearchDialogPresentation(state: state).statusText, Self.notice)

        for accession in ["SRR000001", "SRR000002"] {
            state.sraRunsViewModel.selectedRecords.insert(
                SearchResultRecord(id: accession, accession: accession, title: accession, source: .ena)
            )
        }

        XCTAssertEqual(DatabaseSearchDialogPresentation(state: state).statusText, "2 selected. \(Self.notice)")
    }

    func testOneSelectedRunReadsInTheSingular() {
        let state = DatabaseSearchDialogState(initialDestination: .sraRuns)
        state.sraRunsViewModel.errorMessage = Self.notice
        state.sraRunsViewModel.selectedRecords.insert(
            SearchResultRecord(id: "SRR000001", accession: "SRR000001", title: "SRR000001", source: .ena)
        )

        XCTAssertEqual(DatabaseSearchDialogPresentation(state: state).statusText, "1 selected. \(Self.notice)")
    }
}
