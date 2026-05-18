// ViewerGraphicsExportPanelControllerTests.swift - viewer export panel selection coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

@MainActor
final class ViewerGraphicsExportPanelControllerTests: XCTestCase {
    func testDefaultsToTracksScopeAndRequestedInitialFormat() {
        let controller = ViewerGraphicsExportPanelController(
            formats: [.png, .pdf],
            scopes: [.tracks, .fullViewer, .selectedRegion],
            initialFormat: .pdf
        )

        XCTAssertEqual(controller.selectedScope, .tracks)
        XCTAssertEqual(controller.selectedFormat, .pdf)
        XCTAssertFalse(controller.testingIsScaleSelectionEnabled)
    }

    func testBitmapFormatKeepsScaleSelectionEnabled() {
        let controller = ViewerGraphicsExportPanelController(
            formats: [.png, .pdf],
            scopes: [.tracks, .fullViewer],
            initialFormat: .png
        )

        XCTAssertEqual(controller.selectedFormat, .png)
        XCTAssertTrue(controller.testingIsScaleSelectionEnabled)
        XCTAssertEqual(controller.selectedBitmapScale, 2)
    }

    func testNormalizedOutputURLUsesSelectedFormatExtension() {
        let controller = ViewerGraphicsExportPanelController(
            formats: [.png, .pdf],
            scopes: [.tracks],
            initialFormat: .png
        )
        let rawURL = URL(fileURLWithPath: "/tmp/export.pdf")

        XCTAssertEqual(
            controller.normalizedOutputURL(from: rawURL),
            URL(fileURLWithPath: "/tmp/export.png")
        )
    }
}
