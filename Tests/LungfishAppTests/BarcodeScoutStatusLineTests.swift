// BarcodeScoutStatusLineTests.swift - The drawer's progress line does not outlast a failed barcode search
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane ALERTS (W-18, ruling WALK-UX item 11). Detect set the drawer's status line to "Scouting barcodes..." and
// each progress step of the search wrote another line. When the search failed, the alert closed and the line stayed at the
// last step ("Preparing barcode adapters..."), as though the search were still going. This test drives the drawer's real
// request with a FASTQ file that is not there, so the scout fails before any tool starts, closes the alert, and reads the
// labels of the drawer.

import AppKit
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishApp

@MainActor
final class BarcodeScoutStatusLineTests: XCTestCase {
    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    private static func labels(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview in (subview as? NSTextField).map { [$0] } ?? labels(in: subview) }
    }

    func testTheProgressLineIsGoneWhenTheFailureAlertCloses() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = try XCTUnwrap(harness.split.viewerController)
        viewer.openDemuxSetupDrawer()
        let drawer = try XCTUnwrap(viewer.fastqMetadataDrawerView)
        viewer.currentFASTQDatasetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-reads-\(UUID().uuidString).fastq")
        let step = DemultiplexStep(label: "Detect", barcodeKitID: "truseq-single-a")

        viewer.fastqMetadataDrawerViewDidRequestScout(drawer, step: step)
        XCTAssertTrue(
            Self.labels(in: drawer).contains { $0.stringValue == "Scouting barcodes..." },
            "the drawer says the search began"
        )
        await waitUntil(budget: .lookup) { harness.window.attachedSheet != nil }
        let sheet = try XCTUnwrap(harness.window.attachedSheet, "the failed search raised its alert")
        harness.window.endSheet(sheet)
        await waitUntil(budget: .lookup) { harness.window.attachedSheet == nil }

        let progress = Self.labels(in: drawer).map(\.stringValue).filter {
            $0.hasPrefix("Scouting barcodes") || $0.hasPrefix("Preparing barcode") || $0.hasPrefix("Extracting first")
        }
        XCTAssertTrue(progress.isEmpty, "a search that ended leaves no progress words: \(progress)")
    }
}
