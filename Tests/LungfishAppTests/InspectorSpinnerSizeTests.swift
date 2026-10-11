// InspectorSpinnerSizeTests.swift - Inspector spinners use the small control size, not a scale effect
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import ViewInspector
import XCTest
import LungfishTestSupport
@testable import LungfishApp

/// Walk finding F13. `ProgressView().scaleEffect(0.7)` shrinks the drawn spinner but keeps its
/// full-size layout frame, and SwiftUI logged a size fault each time one appeared. The small
/// control size is the spinner the Inspector means, and it lays out at its own size.
@MainActor
final class InspectorSpinnerSizeTests: XCTestCase {
    private func assertSmallControlSize(
        _ spinner: InspectableView<ViewType.ProgressView>,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            try? spinner.controlSize(), ControlSize.small,
            "\(context) uses the small control size.", file: file, line: line
        )
        XCTAssertNil(
            try? spinner.scaleEffect(),
            "\(context) is not scaled, since a scale effect keeps the full-size frame.", file: file, line: line
        )
    }

    func testTheProvenanceLoadingSpinnerUsesTheSmallControlSize() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.isLoading = true

        let indicator = try ProvenanceSection(viewModel: viewModel).inspect()
            .find(viewWithAccessibilityIdentifier: "provenance-loading-indicator")

        assertSmallControlSize(try indicator.find(ViewType.ProgressView.self), "The loading spinner")
    }

    func testTheLoadingCaptionEndsWithAnEllipsisCharacter() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.isLoading = true

        let texts = try ProvenanceSection(viewModel: viewModel).inspect()
            .find(viewWithAccessibilityIdentifier: "provenance-loading-indicator")
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        XCTAssertEqual(texts, ["Loading provenance\u{2026}"])
    }

    // MARK: - The three spinners of the Analysis section

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func spinners(in window: NSWindow) -> [NSProgressIndicator] {
        window.contentView.map { descendants(of: $0).compactMap { $0 as? NSProgressIndicator } } ?? []
    }

    /// The duplicate and BAM filter spinners show under Filtering, and the mapped reads spinner under
    /// Annotations, so the case hosts the real section and presses the Annotations segment. A scale
    /// effect leaves the AppKit spinner at its regular size, and the small control size sets it small.
    func testTheThreeAnalysisSpinnersAreSmallSpinners() throws {
        let viewModel = ReadStyleSectionViewModel()
        viewModel.hasAlignmentTracks = true
        viewModel.isDuplicateWorkflowRunning = true
        viewModel.isAlignmentFilterWorkflowRunning = true
        viewModel.isMappedReadsAnnotationWorkflowRunning = true
        let window = AccessibilityTreeProbe.host(AnalysisSection(viewModel: viewModel), size: CGSize(width: 320, height: 900))
        addTeardownBlock { window.orderOut(nil) }

        AccessibilityTreeProbe.waitUntil { spinners(in: window).count >= 2 }
        let filtering = spinners(in: window)
        XCTAssertEqual(filtering.count, 2, "Filtering shows the duplicate and the BAM filter spinners.")
        for (index, spinner) in filtering.enumerated() {
            XCTAssertEqual(spinner.controlSize, .small, "Filtering spinner \(index + 1) is a small spinner.")
        }

        let segment = try XCTUnwrap(
            AccessibilityTreeProbe.elements(in: window, labelled: "Annotations").first,
            "The Annotations segment is in the accessibility tree."
        )
        XCTAssertTrue(AccessibilityTreeProbe.press(segment))
        AccessibilityTreeProbe.waitUntil { spinners(in: window).count == 1 }
        let annotations = spinners(in: window)
        XCTAssertEqual(annotations.count, 1, "Annotations shows the mapped reads spinner.")
        XCTAssertEqual(annotations.first?.controlSize, .small, "The mapped reads spinner is a small spinner.")
    }
}
