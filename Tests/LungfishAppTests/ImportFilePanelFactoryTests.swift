// ImportFilePanelFactoryTests.swift - import file panel configuration coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import LungfishApp

@MainActor
final class ImportFilePanelFactoryTests: XCTestCase {
    func testProjectImportPanelMatchesProjectFileImportConfiguration() {
        let panel = ImportFilePanelFactory.projectImportPanel()

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.allowsOtherFileTypes)
        XCTAssertEqual(panel.message, "Select files to import into the project")
        XCTAssertEqual(panel.prompt, "Import")
    }

    func testImportCenterPanelAppliesCardConfigurationAndMessage() {
        let config = ImportCardInfo.OpenPanelConfiguration(
            allowedTypes: [.commaSeparatedText],
            canChooseFiles: true,
            canChooseDirectories: false,
            allowsMultipleSelection: false,
            allowsOtherFileTypes: true
        )

        let panel = ImportFilePanelFactory.importCenterPanel(
            configuration: config,
            message: "Select a FASTQ sample sheet CSV to import"
        )

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.allowsOtherFileTypes)
        XCTAssertEqual(panel.allowedContentTypes, [.commaSeparatedText])
        XCTAssertEqual(panel.message, "Select a FASTQ sample sheet CSV to import")
    }

    func testPrimerSchemeFilePanelUsesRequestedExtensions() throws {
        let panel = ImportFilePanelFactory.primerSchemeFilePanel(extensions: ["tsv", "bed"])

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        let contentTypes = try XCTUnwrap(panel.allowedContentTypes)
        XCTAssertTrue(contentTypes.contains(try XCTUnwrap(UTType(filenameExtension: "tsv"))))
        XCTAssertTrue(contentTypes.contains(try XCTUnwrap(UTType(filenameExtension: "bed"))))
    }
}
