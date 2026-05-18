// SequenceExportPanelControllerTests.swift - sequence export panel accessory coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

@MainActor
final class SequenceExportPanelControllerTests: XCTestCase {
    func testSingleExportControllerConfiguresAccessoryAndSuggestedFilename() {
        let panel = AppFilePanelFactory.sequenceExportPanel()
        let controller = SequenceExportPanelController(
            panel: panel,
            defaultFormat: .genbank,
            filenameBaseName: "sample"
        )

        XCTAssertNotNil(panel.accessoryView)
        XCTAssertEqual(panel.nameFieldStringValue, "sample.gbk")
        XCTAssertEqual(controller.selectedFormat, .genbank)
        XCTAssertEqual(controller.selectedCompression, .none)
    }

    func testBatchExportControllerConfiguresAccessoryWithoutChangingFolderPanelName() {
        let panel = AppFilePanelFactory.batchSequenceExportFolderPanel(itemCount: 3)
        let controller = SequenceExportPanelController(
            panel: panel,
            defaultFormat: .fasta,
            filenameBaseName: nil
        )

        XCTAssertNotNil(panel.accessoryView)
        XCTAssertEqual(controller.selectedFormat, .fasta)
        XCTAssertEqual(controller.selectedCompression, .none)
    }
}
