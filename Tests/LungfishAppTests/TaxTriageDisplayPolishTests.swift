// TaxTriageDisplayPolishTests.swift - Inspector and viewport text around an opened TaxTriage result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp

/// Captures on 9.68 while opening a two-sample TaxTriage result.
@MainActor
final class TaxTriageDisplayPolishTests: XCTestCase {

    func testSummaryPromptHidesOnceABatchResultFillsTheInspector() {
        let viewModel = DocumentSectionViewModel()
        XCTAssertTrue(viewModel.showsMetagenomicsSelectionPrompt)

        viewModel.batchOperationTool = "TaxTriage"
        XCTAssertFalse(
            viewModel.showsMetagenomicsSelectionPrompt,
            "The Summary tab asked for a result above that result's Operation Details"
        )
    }

    func testIgnoredFailureWarningIsPluralizedByCount() {
        XCTAssertEqual(
            MainSplitViewController.taxTriageIgnoredFailureSummary(failureCount: 1, sampleCount: 1),
            "1 ignored failure across 1 sample"
        )
        XCTAssertEqual(
            MainSplitViewController.taxTriageIgnoredFailureSummary(failureCount: 3, sampleCount: 2),
            "3 ignored failures across 2 samples"
        )
        XCTAssertEqual(
            MainSplitViewController.taxTriageIgnoredFailureSummary(failureCount: 2, sampleCount: 0),
            "2 ignored failures"
        )
    }

    func testClassifierAlignmentPaneNeverAsksForASidebarFile() {
        let provider = ClassifierAlignmentEvidenceViewportController()
        _ = provider.viewController
        XCTAssertFalse(provider.viewer.viewerView.showsSidebarPlaceholder)
        XCTAssertTrue(ViewerViewController().loadedViewerShowsSidebarPlaceholder)
    }

    func testDatabaseBuildPlaceholderPaintsOverTheViewportBelow() {
        XCTAssertTrue(DatabaseBuildPlaceholderView().isOpaque)
    }
}

private extension ViewerViewController {
    var loadedViewerShowsSidebarPlaceholder: Bool {
        _ = view
        return viewerView.showsSidebarPlaceholder
    }
}
